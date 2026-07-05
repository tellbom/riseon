import XCTest
@testable import RiseOn

/// Covers task.md S5.2's verification point: overlay updates today's bar
/// close (and open/high/low) from the live quote, volume stays untouched,
/// no overlay outside trading days, and the two warning keys
/// (`intradayVolumeOverlaySkipped` / `intradayBarNotYetAvailable`) show up
/// exactly when expected.
final class RealtimeOverlayTests: XCTestCase {

    private func makeQuote(price: Double, open: Double, high: Double, low: Double) -> Quote {
        guard let symbol = StockSymbol(code: "600519") else {
            fatalError("600519 must be a valid StockSymbol")
        }
        return Quote(
            symbol: symbol,
            name: "贵州茅台",
            price: price,
            previousClose: 1650.0,
            open: open,
            high: high,
            low: low,
            changeAmount: price - 1650.0,
            changePercent: (price - 1650.0) / 1650.0 * 100,
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000),
            orderBook: nil
        )
    }

    private func makeBars() -> [DailyBar] {
        [
            DailyBar(date: "2024-06-03", open: 1660, close: 1670, high: 1675, low: 1655, volume: 40_000),
            DailyBar(date: "2024-06-04", open: 1670, close: 1680, high: 1690, low: 1665, volume: 45_000),
        ]
    }

    func test_lastBarIsToday_overlaysOHLC_leavesVolumeUntouched() {
        var bars = makeBars()
        bars.append(DailyBar(date: "2024-06-05", open: 1680, close: 1685, high: 1695, low: 1678, volume: 50_000))
        let quote = makeQuote(price: 1700, open: 1682, high: 1705, low: 1679)

        let result = RealtimeOverlay.apply(to: bars, quote: quote, isTradingDay: true, today: "2024-06-05")

        let last = result.bars.last!
        XCTAssertEqual(last.close, 1700)
        XCTAssertEqual(last.open, 1682)
        XCTAssertEqual(last.high, 1705)
        XCTAssertEqual(last.low, 1679)
        XCTAssertEqual(last.volume, 50_000, "volume must be left at the daily bar's original value")

        // Earlier bars are untouched.
        XCTAssertEqual(result.bars[0], bars[0])
        XCTAssertEqual(result.bars[1], bars[1])

        XCTAssertEqual(result.warnings, [ContextPackWarningKey.intradayVolumeOverlaySkipped])
    }

    func test_overlayIsDirectOverwrite_notMaxMinMergeWithExistingBar() {
        // Regression guard: must match Python's `_augment_historical_with_realtime`,
        // which overwrites high/low outright rather than merging/max-ing
        // against the existing bar. A quote with a *lower* high than the
        // existing bar's stored high must still win.
        var bars = makeBars()
        bars.append(DailyBar(date: "2024-06-05", open: 1680, close: 1685, high: 1750, low: 1600, volume: 50_000))
        let quote = makeQuote(price: 1700, open: 1682, high: 1705, low: 1679)

        let result = RealtimeOverlay.apply(to: bars, quote: quote, isTradingDay: true, today: "2024-06-05")

        XCTAssertEqual(result.bars.last?.high, 1705, "must overwrite, not keep the old higher high")
        XCTAssertEqual(result.bars.last?.low, 1679, "must overwrite, not keep the old lower low")
    }

    func test_todaysBarNotYetPublished_doesNotSynthesizeOne() {
        let bars = makeBars() // last bar is "2024-06-04"; "today" is "2024-06-05"
        let quote = makeQuote(price: 1700, open: 1682, high: 1705, low: 1679)

        let result = RealtimeOverlay.apply(to: bars, quote: quote, isTradingDay: true, today: "2024-06-05")

        XCTAssertEqual(result.bars, bars, "bars must be unchanged — no synthetic bar appended")
        XCTAssertEqual(result.bars.count, bars.count)
        XCTAssertEqual(
            Set(result.warnings),
            Set([ContextPackWarningKey.intradayVolumeOverlaySkipped, ContextPackWarningKey.intradayBarNotYetAvailable])
        )
    }

    func test_nonTradingDay_skipsOverlayEntirely_noWarnings() {
        var bars = makeBars()
        bars.append(DailyBar(date: "2024-06-05", open: 1680, close: 1685, high: 1695, low: 1678, volume: 50_000))
        let quote = makeQuote(price: 1700, open: 1682, high: 1705, low: 1679)

        let result = RealtimeOverlay.apply(to: bars, quote: quote, isTradingDay: false, today: "2024-06-05")

        XCTAssertEqual(result.bars, bars, "non-trading day: nothing should be overlaid")
        XCTAssertEqual(result.warnings, [], "non-trading day: nothing stale to warn about")
    }

    func test_emptyBars_returnsEmptyWithNoWarnings() {
        let quote = makeQuote(price: 1700, open: 1682, high: 1705, low: 1679)
        let result = RealtimeOverlay.apply(to: [], quote: quote, isTradingDay: true, today: "2024-06-05")

        XCTAssertEqual(result.bars, [])
        XCTAssertEqual(result.warnings, [])
    }
}
