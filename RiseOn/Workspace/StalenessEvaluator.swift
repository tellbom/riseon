import Foundation

/// Pure staleness rule (task.md S12.2, plan.md §10): a workspace's snapshot
/// is stale if its calendar day is before the most recent trading day, or
/// if it's simply too old regardless of trading calendar (a long weekend/
/// holiday gap, or the person just hasn't opened the app in a while).
///
/// Doesn't own any trading-calendar logic itself — same reasoning as
/// `RealtimeOverlay.apply`'s `isTradingDay` parameter (plan.md §6's
/// "纪律": pure function, no I/O, no calendar/holiday knowledge baked in).
/// Callers supply `mostRecentTradingDay` from wherever they get their
/// trading calendar (not built yet — out of scope here).
public enum StalenessEvaluator {
    /// - Parameters:
    ///   - snapshotDate: the workspace's `meta.snapshotDate`. `nil` (never
    ///     initialized) always counts as stale.
    ///   - mostRecentTradingDay: the most recent completed trading day, as
    ///     of `now`.
    ///   - now: injected rather than read internally, so this stays
    ///     deterministic/testable.
    ///   - maxAgeInDays: absolute fallback threshold in calendar days —
    ///     catches cases where a long gap has passed regardless of the
    ///     trading-day comparison above.
    public static func isStale(
        snapshotDate: Date?,
        mostRecentTradingDay: Date,
        now: Date,
        maxAgeInDays: Int = 3,
        calendar: Calendar = .current
    ) -> Bool {
        guard let snapshotDate else { return true }

        let snapshotDay = calendar.startOfDay(for: snapshotDate)
        let tradingDay = calendar.startOfDay(for: mostRecentTradingDay)
        if snapshotDay < tradingDay {
            return true
        }

        let today = calendar.startOfDay(for: now)
        let ageInDays = calendar.dateComponents([.day], from: snapshotDay, to: today).day ?? 0
        return ageInDays > maxAgeInDays
    }
}

extension StockWorkspace {
    /// Re-evaluates staleness (task.md S12.2) and transitions to `.stale`
    /// if warranted. A no-op returning `false` when `state` isn't currently
    /// `.ready`/`.partial` — staleness isn't a meaningful concept for a
    /// workspace that's still initializing or has already failed/gone stale.
    @discardableResult
    public mutating func evaluateStaleness(
        mostRecentTradingDay: Date,
        now: Date = Date(),
        maxAgeInDays: Int = 3,
        calendar: Calendar = .current
    ) throws -> Bool {
        guard state == .ready || state == .partial else { return false }

        let stale = StalenessEvaluator.isStale(
            snapshotDate: meta.snapshotDate,
            mostRecentTradingDay: mostRecentTradingDay,
            now: now,
            maxAgeInDays: maxAgeInDays,
            calendar: calendar
        )
        guard stale else { return false }

        try transition(to: .stale)
        return true
    }
}
