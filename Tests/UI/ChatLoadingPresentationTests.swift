import XCTest
@testable import RiseOn

final class ChatLoadingPresentationTests: XCTestCase {

    func test_shouldShowAnswerSpinner_afterSearchBeforeFirstAnswerDelta() {
        XCTAssertTrue(
            ChatLoadingPresentation.shouldShowAnswerSpinner(
                isStreaming: true,
                streamingText: "",
                thinkingLines: ["已汇总：本轮检索 12 条研报。"]
            )
        )
    }

    func test_shouldShowAnswerSpinner_hidesOnceAnswerStarts() {
        XCTAssertFalse(
            ChatLoadingPresentation.shouldShowAnswerSpinner(
                isStreaming: true,
                streamingText: "回答开始",
                thinkingLines: ["已汇总：本轮检索 12 条研报。"]
            )
        )
    }
}
