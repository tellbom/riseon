import XCTest
@testable import RiseOn

final class LLMStreamDiagnosticsTests: XCTestCase {

    func test_record_tracksRealDeltasAndFirstDeltaLatency() {
        let start = Date(timeIntervalSince1970: 100)
        var diagnostics = LLMStreamDiagnostics(startedAt: start)

        diagnostics.record(delta: "你好", receivedAt: Date(timeIntervalSince1970: 103))
        diagnostics.record(delta: "，真实流式", receivedAt: Date(timeIntervalSince1970: 104))

        XCTAssertEqual(diagnostics.deltaCount, 2)
        XCTAssertEqual(diagnostics.receivedCharacterCount, 7)
        XCTAssertEqual(diagnostics.largestDeltaCharacterCount, 5)
        XCTAssertEqual(diagnostics.secondsToFirstDelta, 3)
        XCTAssertFalse(diagnostics.isLikelyBuffered)
    }

    func test_isLikelyBuffered_whenOneLargeDeltaArrives() {
        var diagnostics = LLMStreamDiagnostics(startedAt: Date(timeIntervalSince1970: 100))
        diagnostics.record(delta: String(repeating: "字", count: 900), receivedAt: Date(timeIntervalSince1970: 130))

        XCTAssertTrue(diagnostics.isLikelyBuffered)
    }
}
