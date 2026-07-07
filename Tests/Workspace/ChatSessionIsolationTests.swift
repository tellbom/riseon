import XCTest
@testable import RiseOn

/// Covers task.md S11.1's verification point: "A 股会话不出现在 B 股上下文"
/// (stock A's session never appears in stock B's context) — both as direct
/// code-level assertions on `StockWorkspace`'s isolation-enforcing methods,
/// and as an end-to-end check through real persistence (`WorkspaceStore`)
/// and prompt rendering (`PromptBuilder`), since the data model alone
/// passing round-trip tests wouldn't catch a bug in how callers wire two
/// workspaces together.
final class ChatSessionIsolationTests: XCTestCase {

    // MARK: - Direct isolation checks

    func test_appendChatMessage_succeedsWhenCodesMatch() throws {
        var workspace = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh")
        try workspace.appendChatMessage(ChatMessage(role: .user, content: "现在能买吗？"))

        XCTAssertEqual(workspace.chatSession.messages.count, 1)
        XCTAssertEqual(workspace.chatSession.messages.first?.content, "现在能买吗？")
    }

    func test_appendChatMessage_throwsWhenChatSessionCodeHasDrifted() {
        var workspace = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh")
        // Simulate the exact bug this guards against: a session belonging
        // to a different stock ends up attached to this workspace.
        workspace.chatSession = ChatSession(code: "000001", messages: [])

        XCTAssertThrowsError(try workspace.appendChatMessage(ChatMessage(role: .user, content: "?"))) { error in
            guard case StockWorkspace.ChatIsolationError.codeMismatch(let sessionCode, let workspaceCode) = error else {
                return XCTFail("expected .codeMismatch, got \(error)")
            }
            XCTAssertEqual(sessionCode, "000001")
            XCTAssertEqual(workspaceCode, "600519")
        }
        // The bad append must not have gone through.
        XCTAssertTrue(workspace.chatSession.messages.isEmpty)
    }

    func test_replaceChatSession_succeedsWhenCodeMatches() throws {
        var workspace = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh")
        let newSession = ChatSession(code: "600519", messages: [ChatMessage(role: .assistant, content: "已恢复历史")])
        try workspace.replaceChatSession(with: newSession)
        XCTAssertEqual(workspace.chatSession, newSession)
    }

    func test_replaceChatSession_rejectsMismatchedCode() {
        var workspace = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh")
        let wrongSession = ChatSession(code: "000001", messages: [ChatMessage(role: .user, content: "这是平安银行的问题")])

        XCTAssertThrowsError(try workspace.replaceChatSession(with: wrongSession))
        // Original (empty, correctly-coded) session must be untouched.
        XCTAssertEqual(workspace.chatSession.code, "600519")
        XCTAssertTrue(workspace.chatSession.messages.isEmpty)
    }

    func test_assertChatSessionIsolated_passesForFreshWorkspace() throws {
        let workspace = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh")
        try workspace.assertChatSessionIsolated() // must not throw
    }

    // MARK: - End-to-end: persistence never mixes two stocks' histories

    private func makeTempStore() throws -> WorkspaceStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatIsolationTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try WorkspaceStore(directory: directory)
    }

    func test_twoWorkspaces_persistedAndReloaded_neverMixHistories() async throws {
        let store = try makeTempStore()

        var workspaceA = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh")
        try workspaceA.appendChatMessage(ChatMessage(role: .user, content: "茅台现在贵不贵？"))
        try workspaceA.appendChatMessage(ChatMessage(role: .assistant, content: "茅台的回答"))

        var workspaceB = StockWorkspace(code: "000001", name: "平安银行", market: "sz")
        try workspaceB.appendChatMessage(ChatMessage(role: .user, content: "平安银行值得抄底吗？"))
        try workspaceB.appendChatMessage(ChatMessage(role: .assistant, content: "平安银行的回答"))

        try await store.save(workspaceA)
        try await store.save(workspaceB)

        let reloadedA = try await store.load(code: "600519")
        let reloadedB = try await store.load(code: "000001")

        XCTAssertEqual(reloadedA?.chatSession.messages.map(\.content), ["茅台现在贵不贵？", "茅台的回答"])
        XCTAssertEqual(reloadedB?.chatSession.messages.map(\.content), ["平安银行值得抄底吗？", "平安银行的回答"])

        // The actual "never appears in the other's context" assertion:
        let aContents = Set(reloadedA?.chatSession.messages.map(\.content) ?? [])
        let bContents = Set(reloadedB?.chatSession.messages.map(\.content) ?? [])
        XCTAssertTrue(aContents.isDisjoint(with: bContents))

        try reloadedA?.assertChatSessionIsolated()
        try reloadedB?.assertChatSessionIsolated()
    }

    // MARK: - End-to-end: PromptBuilder only ever renders the workspace it was given

    func test_promptBuilder_neverLeaksTheOtherWorkspacesHistory() {
        var workspaceA = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh")
        try? workspaceA.appendChatMessage(ChatMessage(role: .user, content: "只属于茅台的问题内容"))

        var workspaceB = StockWorkspace(code: "000001", name: "平安银行", market: "sz")
        try? workspaceB.appendChatMessage(ChatMessage(role: .user, content: "只属于平安银行的问题内容"))

        let packA = ContextPack(subject: ContextPackSubject(code: workspaceA.code, stockName: workspaceA.name))
        let promptA = PromptBuilder.build(pack: packA, ruleScore: nil, history: workspaceA.chatSession.messages, question: "新问题")

        XCTAssertTrue(promptA.user.contains("只属于茅台的问题内容"))
        XCTAssertFalse(promptA.user.contains("只属于平安银行的问题内容"), "workspace B's history must never appear in workspace A's prompt")
    }
}
