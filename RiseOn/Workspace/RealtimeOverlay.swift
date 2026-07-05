import Foundation

/// Step B of the initialization pipeline: overlays the latest real-time quote
/// onto today's daily bar (task.md S5.2, plan.md §6 Step B, §0.5-4/§0.5-7).
///
/// Pure function, no network I/O — callers fetch `[DailyBar]` via
/// `TencentDailyProvider` and a `Quote` via `TencentQuoteProvider`
/// separately (Steps A and B's own data sources) and hand both here.
///
/// MVP scope — these are decided defaults (plan.md §0.5-4/§0.5-7), not open
/// questions:
/// - Only `close`/`open`/`high`/`low` are overlaid, as **direct overwrites**
///   with the quote's own values — mirroring Python's
///   `_augment_historical_with_realtime`, which does the same (it does not
///   merge/max against the existing bar's high/low; Tencent's realtime quote
///   already reports the day's cumulative high/low, not just the latest
///   tick). `volume` is left at the daily bar's original value — `Quote` has
///   no whole-day volume field to overlay with — and this always adds
///   `intradayVolumeOverlaySkipped`.
/// - If the last daily bar's date is already `today`, its OHLC is updated in
///   place. If it's still an earlier date (the daily endpoint hasn't
///   published today's bar yet), MVP does **not** synthesize one —
///   `dailyBars`/`technical` keep using the most recent close, only the
///   quote itself reflects the live price. This adds `intradayBarNotYetAvailable`.
/// - On a non-trading day, nothing is overlaid and no warnings are added —
///   the last bar already **is** the correct most-recent close; there's
///   nothing stale to flag.
public enum RealtimeOverlay {

    public struct Result: Equatable, Sendable {
        public var bars: [DailyBar]
        public var warnings: [String]

        public init(bars: [DailyBar], warnings: [String]) {
            self.bars = bars
            self.warnings = warnings
        }
    }

    /// - Parameters:
    ///   - bars: daily bars, ascending by date (oldest first) — the same
    ///     order `TencentDailyProvider.fetchDailyBars` returns.
    ///   - quote: the latest real-time quote for the same stock.
    ///   - isTradingDay: whether `today` is a trading day for this stock's
    ///     market (weekends/holidays are not) — mirrors Python's
    ///     `is_market_open(market, market_today)`, which despite the name
    ///     checks the *day*, not the intraday minute-by-minute session
    ///     window. Callers derive this from their own trading calendar;
    ///     `RealtimeOverlay` doesn't own calendar logic, staying a pure
    ///     function per plan.md §6's "纪律".
    ///   - today: `"yyyy-MM-dd"`, same format as `DailyBar.date` — injected
    ///     rather than read from `Date()` internally, so this stays
    ///     pure/deterministic and testable.
    public static func apply(
        to bars: [DailyBar],
        quote: Quote,
        isTradingDay: Bool,
        today: String
    ) -> Result {
        guard isTradingDay, let lastBar = bars.last else {
            return Result(bars: bars, warnings: [])
        }

        var warnings = [ContextPackWarningKey.intradayVolumeOverlaySkipped]

        guard lastBar.date == today else {
            // Today's bar hasn't been published by the daily endpoint yet —
            // MVP does not synthesize one (plan.md §0.5-7).
            warnings.append(ContextPackWarningKey.intradayBarNotYetAvailable)
            return Result(bars: bars, warnings: warnings)
        }

        var updated = bars
        let lastIndex = updated.count - 1
        updated[lastIndex].close = quote.price
        updated[lastIndex].open = quote.open
        updated[lastIndex].high = quote.high
        updated[lastIndex].low = quote.low
        // volume intentionally left untouched.

        return Result(bars: updated, warnings: warnings)
    }
}
