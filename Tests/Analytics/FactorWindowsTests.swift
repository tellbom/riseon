import XCTest
@testable import RiseOn

/// Covers task.md S6.3's verification point. Expected values were generated
/// by actually running `llm_factor_summary.py::_period_return`/
/// `_range_position`'s exact formulas (including `_compact_number`'s
/// round-to-4-decimals) against pandas on the same 30-bar fixture used in
/// `TechnicalIndicatorsTests`, then transcribed verbatim — not hand-computed.
final class FactorWindowsTests: XCTestCase {

    private let closes: [Double] = [10.0, 10.2, 10.15, 10.3, 10.45, 10.4, 10.55, 10.7, 10.65, 10.8, 10.9, 10.85, 11.0, 11.1, 11.05, 10.95, 10.85, 10.9, 11.05, 11.2, 11.15, 11.3, 11.45, 11.4, 11.55, 11.5, 11.65, 11.6, 11.75, 11.9]
    private let highs: [Double] = [10.1, 10.3, 10.25, 10.4, 10.55, 10.5, 10.65, 10.8, 10.75, 10.9, 11.0, 10.95, 11.1, 11.2, 11.15, 11.05, 10.95, 11.0, 11.15, 11.3, 11.25, 11.4, 11.55, 11.5, 11.65, 11.6, 11.75, 11.7, 11.85, 12.0]
    private let lows: [Double] = [9.9, 10.1, 10.05, 10.2, 10.35, 10.3, 10.45, 10.6, 10.55, 10.7, 10.8, 10.75, 10.9, 11.0, 10.95, 10.85, 10.75, 10.8, 10.95, 11.1, 11.05, 11.2, 11.35, 11.3, 11.45, 11.4, 11.55, 11.5, 11.65, 11.8]

    private func makeBars(count: Int? = nil) -> [DailyBar] {
        let n = count ?? closes.count
        return (0..<n).map { i in
            DailyBar(date: "d\(i)", open: closes[i], close: closes[i], high: highs[i], low: lows[i], volume: 10_000)
        }
    }

    // MARK: - periodReturn parity (reference: real _period_return + _pct_change output)

    func test_periodReturn_matchesReferenceForAllDecisionWindows() {
        let bars = makeBars()
        XCTAssertEqual(FactorWindows.periodReturn(bars: bars, periods: 1)!, 1.2766, accuracy: 1e-4)
        XCTAssertEqual(FactorWindows.periodReturn(bars: bars, periods: 3)!, 2.1459, accuracy: 1e-4)
        XCTAssertEqual(FactorWindows.periodReturn(bars: bars, periods: 5)!, 3.0303, accuracy: 1e-4)
        XCTAssertEqual(FactorWindows.periodReturn(bars: bars, periods: 10)!, 6.25, accuracy: 1e-4)
        XCTAssertEqual(FactorWindows.periodReturn(bars: bars, periods: 20)!, 10.1852, accuracy: 1e-4)
    }

    func test_windowReturns_returnsAllFiveDecisionWindows() {
        let bars = makeBars()
        let returns = FactorWindows.windowReturns(bars: bars)
        XCTAssertEqual(returns.keys.sorted(), FactorWindows.decisionWindows.sorted())
        XCTAssertEqual(returns[1]!, 1.2766, accuracy: 1e-4)
        XCTAssertEqual(returns[20]!, 10.1852, accuracy: 1e-4)
    }

    func test_periodReturn_notEnoughHistory_returnsNil() {
        // Python: `len(df) <= periods -> None`. 3 bars, periods=3 -> nil (not <, so equal-length also nils out).
        let bars = makeBars(count: 3)
        XCTAssertEqual(FactorWindows.periodReturn(bars: bars, periods: 1)!, -0.4902, accuracy: 1e-4)
        XCTAssertNil(FactorWindows.periodReturn(bars: bars, periods: 3))
        XCTAssertNil(FactorWindows.periodReturn(bars: bars, periods: 5))
    }

    func test_periodReturn_zeroBaseClose_returnsNil() {
        var bars = makeBars(count: 2)
        bars[0].close = 0
        XCTAssertNil(FactorWindows.periodReturn(bars: bars, periods: 1))
    }

    // MARK: - rangePosition parity (reference: real _range_position output)

    func test_rangePosition_matchesReferenceAtDefaultWindow20() {
        let bars = makeBars()
        XCTAssertEqual(FactorWindows.rangePosition(bars: bars)!, 0.92, accuracy: 1e-4)
    }

    func test_rangePosition_matchesReferenceAtWindow5() {
        let bars = makeBars()
        XCTAssertEqual(FactorWindows.rangePosition(bars: bars, window: 5)!, 0.8333, accuracy: 1e-4)
    }

    func test_rangePosition_shortSeries_windowLargerThanHistory_stillComputesOverWhatExists() {
        // Python's `df.tail(window)` just returns the whole (short) frame
        // when window > len(df) — same as Swift's `suffix(_:)` clamping.
        let bars = makeBars(count: 3)
        XCTAssertEqual(FactorWindows.rangePosition(bars: bars, window: 20)!, 0.625, accuracy: 1e-4)
    }

    func test_rangePosition_fewerThanTwoBars_returnsNil() {
        let bars = makeBars(count: 1)
        XCTAssertNil(FactorWindows.rangePosition(bars: bars, window: 20))
    }

    func test_rangePosition_degenerateRange_highEqualsLow_returnsNil() {
        let bars = [
            DailyBar(date: "d0", open: 10, close: 10, high: 10, low: 10, volume: 1),
            DailyBar(date: "d1", open: 10, close: 10, high: 10, low: 10, volume: 1),
        ]
        XCTAssertNil(FactorWindows.rangePosition(bars: bars, window: 20))
    }

    // MARK: - Constants

    func test_decisionWindowsAndComputeWindowBars_matchPythonConstants() {
        XCTAssertEqual(FactorWindows.decisionWindows, [1, 3, 5, 10, 20])
        XCTAssertEqual(FactorWindows.computeWindowBars, 120)
    }
}
