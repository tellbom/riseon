import Foundation

/// Swift rewrite of the `technical` slice of `quant_factor_context.py` /
/// `llm_factor_summary.py` (task.md S6.3, plan.md §2.2/§7).
///
/// Pure functions, no I/O — same "纪律" as `TechnicalIndicators`.
public enum FactorWindows {

    /// `quant_factor_context.py::DECISION_WINDOWS`.
    public static let decisionWindows = [1, 3, 5, 10, 20]

    /// `quant_factor_context.py::COMPUTE_WINDOW_BARS` — how many trailing
    /// bars the real pipeline feeds into factor computation
    /// (`df.tail(COMPUTE_WINDOW_BARS)` upstream, in the eventual
    /// `ContextPackBuilder`, S8). `FactorWindows` itself doesn't slice
    /// internally — it works on whatever `bars` it's given — this constant
    /// is exposed purely for that future caller to apply before calling in.
    public static let computeWindowBars = 120

    /// Mirrors `llm_factor_summary.py::_period_return`: percentage change of
    /// `close` over `periods` bars, rounded to 4 decimals (matching
    /// `_compact_number`'s rounding). `nil` when there isn't enough history
    /// (`bars.count <= periods`, same as Python's `len(df) <= periods`) or
    /// the base close is exactly `0`.
    public static func periodReturn(bars: [DailyBar], periods: Int) -> Double? {
        guard bars.count > periods else { return nil }
        let latest = bars[bars.count - 1].close
        let base = bars[bars.count - 1 - periods].close
        guard base != 0 else { return nil }
        return compactNumber((latest - base) / base * 100)
    }

    /// Mirrors `_range_position`: where the latest `close` sits within the
    /// high/low range of the trailing `window` bars, as a **0-1 ratio**
    /// (not a percentage — unlike `periodReturn`), rounded to 4 decimals.
    /// `nil` when there are under 2 bars total, or the range is degenerate
    /// (`high == low`). Real usage in `quant_factor_context.py` only ever
    /// calls this with `window: 20` (not once per decision window like
    /// `periodReturn`) — that's why the default is 20, not a batch API.
    public static func rangePosition(bars: [DailyBar], window: Int = 20) -> Double? {
        guard bars.count >= 2 else { return nil }
        let tail = bars.suffix(window)
        guard let low = tail.map(\.low).min(), let high = tail.map(\.high).max(), high != low else {
            return nil
        }
        let close = bars[bars.count - 1].close
        return compactNumber((close - low) / (high - low))
    }

    /// `periodReturn` for every standard decision window (1/3/5/10/20),
    /// skipping windows that return `nil` (not enough history yet).
    public static func windowReturns(bars: [DailyBar], windows: [Int] = FactorWindows.decisionWindows) -> [Int: Double] {
        var result: [Int: Double] = [:]
        for window in windows {
            if let value = periodReturn(bars: bars, periods: window) {
                result[window] = value
            }
        }
        return result
    }

    /// Matches `_compact_number`'s `round(value, 4)`. Python 3's `round()`
    /// uses round-half-to-even; `.toNearestOrEven` is the closest Swift
    /// equivalent. In practice real price data essentially never lands
    /// exactly on a rounding boundary, so this is a best-effort match for
    /// that theoretical edge case rather than a guaranteed bit-for-bit one.
    private static func compactNumber(_ value: Double, digits: Int = 4) -> Double? {
        guard value.isFinite else { return nil }
        let multiplier = pow(10.0, Double(digits))
        return (value * multiplier).rounded(.toNearestOrEven) / multiplier
    }
}
