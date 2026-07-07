import Foundation

/// Fetches daily-bar history behind a replaceable boundary — the
/// `DailyBar`-fetching counterpart to `QuoteProvider` (`Shared/QuoteProvider/QuoteProvider.swift`).
///
/// Added in S16 specifically so `WorkspaceInitializationCoordinator` can be
/// unit-tested against a mock instead of a real network call, matching how
/// `QuoteProvider` already lets `TencentQuoteProvider` be swapped out.
/// `TencentDailyProvider` (S5.1) now conforms to this — an additive change,
/// its method signature already matched exactly.
public protocol DailyBarsProvider: Sendable {
    func fetchDailyBars(fullSymbol: String, start: String, end: String, lookback: Int) async throws -> [DailyBar]
}
