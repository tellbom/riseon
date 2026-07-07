import XCTest
@testable import RiseOn

/// Covers task.md S16.5's actual "ask a question" flow: `PromptBuilder` +
/// `LLMService` + `ChatThread` wired together and exercised end-to-end
/// (with a mock `LLMService`, since a real one needs a live API key and
/// network — task.md S16.5's "真机问答" is explicitly a real-device check).
final class WorkspaceChatServiceTests: XCTestCase {

    private struct MockLLMService: LLMService {
        var response: Result<String, LLMServiceError>

        func generate(system: String, user: String) async throws -> String {
            switch response {
            case .success(let text): return text
            case .failure(let error): throw error
            }
        }

        func streamGenerate(system: String, user: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                switch response {
                case .success(let text):
                    continuation.yield(text)
                    continuation.finish()
                case .failure(let error):
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func makeReadyWorkspace() throws -> StockWorkspace {
        var workspace = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh")
        try workspace.transition(to: .initializing)
        try workspace.applyRefreshedPack(
            ContextPack(subject: ContextPackSubject(code: "600519", stockName: "贵州茅台", market: "sh"), dataQuality: DataQuality(level: "good")),
            ruleScore: RuleScore(code: "600519", signalScore: 71),
            snapshotDate: Date(),
            source: "tencent"
        )
        return workspace
    }

    func test_ask_appendsQuestionAndAnswer_returnsAnswer() async throws {
        var workspace = try makeReadyWorkspace()
        let llm = MockLLMService(response: .success("这是模型的回答"))

        let answer = try await WorkspaceChatService.ask("现在能买吗？", in: &workspace, llmService: llm)

        XCTAssertEqual(answer, "这是模型的回答")
        XCTAssertEqual(workspace.activeChatThread?.messages.count, 2)
        XCTAssertEqual(workspace.activeChatThread?.messages[0].role, .user)
        XCTAssertEqual(workspace.activeChatThread?.messages[0].content, "现在能买吗？")
        XCTAssertEqual(workspace.activeChatThread?.messages[1].role, .assistant)
        XCTAssertEqual(workspace.activeChatThread?.messages[1].content, "这是模型的回答")
    }

    func test_ask_withoutContextPack_throwsWorkspaceNotReady() async {
        var workspace = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh") // no pack yet
        let llm = MockLLMService(response: .success("不应该被调用"))

        do {
            _ = try await WorkspaceChatService.ask("?", in: &workspace, llmService: llm)
            XCTFail("expected .workspaceNotReady to be thrown")
        } catch let error as WorkspaceChatService.ChatServiceError {
            XCTAssertEqual(error, .workspaceNotReady)
        } catch {
            XCTFail("expected ChatServiceError, got \(error)")
        }
        XCTAssertTrue(workspace.activeChatThread?.messages.isEmpty ?? false, "nothing should be recorded if we never had a pack to ask against")
    }

    func test_ask_llmFailure_stillRecordsTheQuestion_butNotAnAnswer() async throws {
        var workspace = try makeReadyWorkspace()
        let llm = MockLLMService(response: .failure(.timeout))

        do {
            _ = try await WorkspaceChatService.ask("现在能买吗？", in: &workspace, llmService: llm)
            XCTFail("expected the LLM error to propagate")
        } catch let error as LLMServiceError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("expected LLMServiceError, got \(error)")
        }

        XCTAssertEqual(workspace.activeChatThread?.messages.count, 1, "the question itself must not be lost")
        XCTAssertEqual(workspace.activeChatThread?.messages[0].role, .user)
        XCTAssertEqual(workspace.activeChatThread?.messages[0].content, "现在能买吗？")
    }

    func test_ask_usesThisWorkspacesOwnHistoryAndPack_notAnyOthers() async throws {
        var workspaceA = try makeReadyWorkspace()
        try workspaceA.appendChatMessage(ChatMessage(role: .user, content: "上一轮关于茅台的问题"))

        let llm = MockLLMService(response: .success("回答"))
        _ = try await WorkspaceChatService.ask("新问题", in: &workspaceA, llmService: llm)

        // Just confirms the call succeeded end-to-end against this
        // workspace's own state without needing a second workspace to
        // compare against here -- cross-stock isolation itself is already
        // covered by `ChatThreadIsolationTests` (S11); this test is about
        // `WorkspaceChatService` actually reading `workspace.activeChatThread`/
        // `workspace.contextPack` rather than some other source.
        XCTAssertEqual(workspaceA.activeChatThread?.messages.count, 3)
        XCTAssertEqual(workspaceA.activeChatThread?.messages[0].content, "上一轮关于茅台的问题")
        XCTAssertEqual(workspaceA.activeChatThread?.messages[1].content, "新问题")
        XCTAssertEqual(workspaceA.activeChatThread?.messages[2].content, "回答")
    }

    // MARK: - streamAsk / finalizeStreamedAnswer

    func test_streamAsk_appendsQuestionImmediately_andStreamYieldsAnswer() async throws {
        var workspace = try makeReadyWorkspace()
        let llm = MockLLMService(response: .success("流式回答"))

        let stream = try WorkspaceChatService.streamAsk("现在能买吗？", in: &workspace, llmService: llm)

        // The question is recorded before the first token is even consumed.
        XCTAssertEqual(workspace.activeChatThread?.messages.count, 1)
        XCTAssertEqual(workspace.activeChatThread?.messages[0].content, "现在能买吗？")

        var accumulated = ""
        for try await delta in stream {
            accumulated += delta
        }
        XCTAssertEqual(accumulated, "流式回答")

        // Nothing appended for the assistant side until finalize is called.
        XCTAssertEqual(workspace.activeChatThread?.messages.count, 1)

        try WorkspaceChatService.finalizeStreamedAnswer(accumulated, in: &workspace)

        XCTAssertEqual(workspace.activeChatThread?.messages.count, 2)
        XCTAssertEqual(workspace.activeChatThread?.messages[1].role, .assistant)
        XCTAssertEqual(workspace.activeChatThread?.messages[1].content, "流式回答")
    }

    func test_streamAsk_withoutContextPack_throwsWorkspaceNotReady() {
        var workspace = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh")
        let llm = MockLLMService(response: .success("不应该被调用"))

        XCTAssertThrowsError(try WorkspaceChatService.streamAsk("?", in: &workspace, llmService: llm)) { error in
            guard case WorkspaceChatService.ChatServiceError.workspaceNotReady = error else {
                return XCTFail("expected .workspaceNotReady, got \(error)")
            }
        }
        XCTAssertTrue(workspace.activeChatThread?.messages.isEmpty ?? false)
    }

    func test_streamAsk_llmFailure_questionRecorded_finalizeNeverCalled() async throws {
        var workspace = try makeReadyWorkspace()
        let llm = MockLLMService(response: .failure(.timeout))

        let stream = try WorkspaceChatService.streamAsk("现在能买吗？", in: &workspace, llmService: llm)
        XCTAssertEqual(workspace.activeChatThread?.messages.count, 1)

        do {
            for try await _ in stream {}
            XCTFail("expected the LLM error to propagate")
        } catch let error as LLMServiceError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("expected LLMServiceError, got \(error)")
        }

        // No assistant message -- caller correctly never calls finalize on error.
        XCTAssertEqual(workspace.activeChatThread?.messages.count, 1)
    }
}
