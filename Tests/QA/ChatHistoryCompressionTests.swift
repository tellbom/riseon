import XCTest
@testable import RiseOn

/// Covers task.md S11.2's verification point: long sessions don't exceed
/// the model's context (via token-budget truncation, the MVP mechanism)
/// and the summary-compression interface has a placeholder implementation.
final class ChatHistoryCompressionTests: XCTestCase {

    // MARK: - estimatedTokenCount

    func test_estimatedTokenCount_emptyString_isZero() {
        XCTAssertEqual(ChatHistoryCompression.estimatedTokenCount(""), 0)
    }

    func test_estimatedTokenCount_matchesLengthDividedByThreeRoundedUp() {
        XCTAssertEqual(ChatHistoryCompression.estimatedTokenCount("a"), 1) // ceil(1/3)
        XCTAssertEqual(ChatHistoryCompression.estimatedTokenCount("abc"), 1) // ceil(3/3)
        XCTAssertEqual(ChatHistoryCompression.estimatedTokenCount("abcd"), 2) // ceil(4/3)
        XCTAssertEqual(ChatHistoryCompression.estimatedTokenCount("123456789"), 3) // ceil(9/3)
    }

    // MARK: - truncate

    /// Four messages, each exactly 9 characters (-> 3 estimated tokens
    /// each), so budget math is exact and unambiguous.
    private func makeMessages() -> [ChatMessage] {
        [
            ChatMessage(role: .user, content: "message-1"),
            ChatMessage(role: .assistant, content: "message-2"),
            ChatMessage(role: .user, content: "message-3"),
            ChatMessage(role: .assistant, content: "message-4"),
        ]
    }

    func test_truncate_keepsMostRecentMessages_dropsOldestFirst() {
        let messages = makeMessages() // 3 tokens each
        let kept = ChatHistoryCompression.truncate(messages, toFit: 6) // fits exactly 2

        XCTAssertEqual(kept.map(\.content), ["message-3", "message-4"], "must keep the 2 most recent, in original order")
    }

    func test_truncate_budgetLargerThanEverything_keepsAll() {
        let messages = makeMessages()
        let kept = ChatHistoryCompression.truncate(messages, toFit: 1000)
        XCTAssertEqual(kept, messages)
    }

    func test_truncate_exactBudgetFit_keepsExactlyThatMany() {
        let messages = makeMessages() // 3 tokens each, 4 messages = 12 total
        let kept = ChatHistoryCompression.truncate(messages, toFit: 12)
        XCTAssertEqual(kept, messages, "budget exactly equals total -> nothing dropped")
    }

    func test_truncate_zeroBudget_returnsEmpty() {
        XCTAssertEqual(ChatHistoryCompression.truncate(makeMessages(), toFit: 0), [])
    }

    func test_truncate_negativeBudget_returnsEmpty() {
        XCTAssertEqual(ChatHistoryCompression.truncate(makeMessages(), toFit: -5), [])
    }

    func test_truncate_emptyMessages_returnsEmpty() {
        XCTAssertEqual(ChatHistoryCompression.truncate([], toFit: 100), [])
    }

    func test_truncate_singleOversizedLatestMessage_dropsItEntirely() {
        // Known, documented MVP limitation: this strategy only drops whole
        // messages, never partially truncates one -- so if even the single
        // most recent message alone exceeds the budget, the result is
        // empty rather than a clipped fragment of it. This only affects the
        // *history* passed to `PromptBuilder`; the current question itself
        // is a separate parameter and is never dropped.
        let hugeMessage = [ChatMessage(role: .user, content: String(repeating: "x", count: 300))] // ~100 tokens
        let kept = ChatHistoryCompression.truncate(hugeMessage, toFit: 10)
        XCTAssertEqual(kept, [])
    }

    func test_truncate_preservesChronologicalOrder() {
        let messages = makeMessages()
        let kept = ChatHistoryCompression.truncate(messages, toFit: 9) // fits 3 of 4
        XCTAssertEqual(kept.map(\.content), ["message-2", "message-3", "message-4"])
    }

    // MARK: - Summary compression placeholder

    func test_chatSummarySection_hasExactlyFiveHeadersMatchingPython() {
        XCTAssertEqual(ChatSummarySection.allCases.count, 5)
        XCTAssertEqual(ChatSummarySection.summary.rawValue, "## 会话摘要")
        XCTAssertEqual(ChatSummarySection.subject.rawValue, "## 当前关注标的")
        XCTAssertEqual(ChatSummarySection.preferences.rawValue, "## 用户偏好与约束")
        XCTAssertEqual(ChatSummarySection.judgments.rawValue, "## 已有判断与操作条件")
        XCTAssertEqual(ChatSummarySection.risks.rawValue, "## 风险、数据时效与未决问题")
    }

    func test_unimplementedSummarizer_alwaysThrowsNotImplemented() async {
        let summarizer: ChatHistorySummarizer = UnimplementedChatHistorySummarizer()
        do {
            _ = try await summarizer.summarize(messages: makeMessages(), previousSummary: nil)
            XCTFail("expected .notImplemented to be thrown")
        } catch let error as ChatHistorySummarizerError {
            XCTAssertEqual(error, .notImplemented)
        } catch {
            XCTFail("expected ChatHistorySummarizerError, got \(error)")
        }
    }

    func test_summarizerProtocol_acceptsAnyConformer() async throws {
        // Proves the interface itself is a usable injection point (mirrors
        // S10.1's "protocol accepts a mock" pattern), even though the only
        // real conformer today always fails.
        struct StubSummarizer: ChatHistorySummarizer {
            func summarize(messages: [ChatMessage], previousSummary: String?) async throws -> String {
                "## 会话摘要\nstub"
            }
        }
        let summarizer: ChatHistorySummarizer = StubSummarizer()
        let result = try await summarizer.summarize(messages: [], previousSummary: nil)
        XCTAssertTrue(result.contains("## 会话摘要"))
    }
}
