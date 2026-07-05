import Foundation

/// One qfq-adjusted daily OHLCV bar (task.md S5.1, plan.md §2.1/§6 Step A).
///
/// **Field order note**: Tencent's `qfqday` rows are
/// `[date, open, close, high, low, volume, amount?]` — **not**
/// `[date, open, high, low, close, volume]` like you'd naturally guess.
/// `close` comes third, before `high`/`low`. Get this backwards and every
/// bar's close/high end up silently swapped (verified against
/// `data_provider/tencent_fetcher.py::_extract_kline_rows`).
public struct DailyBar: Codable, Equatable, Hashable, Sendable {
    /// `"yyyy-MM-dd"`, as returned by the endpoint.
    public var date: String
    public var open: Double
    public var close: Double
    public var high: Double
    public var low: Double
    /// Shares, not lots — already multiplied by 100 from the raw response,
    /// mirroring `tencent_fetcher.py::_lots_to_shares`.
    public var volume: Double
    /// Not always present in the response.
    public var amount: Double?

    public init(
        date: String,
        open: Double,
        close: Double,
        high: Double,
        low: Double,
        volume: Double,
        amount: Double? = nil
    ) {
        self.date = date
        self.open = open
        self.close = close
        self.high = high
        self.low = low
        self.volume = volume
        self.amount = amount
    }
}
