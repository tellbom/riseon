import Foundation

/// Fetches qfq-adjusted daily bars from the same Tencent endpoint family as
/// `TencentMinuteProvider` (task.md S5.1/S5.3, plan.md §2.1/§6 Step A).
///
/// **Why this takes a `fullSymbol: String` instead of a `StockSymbol` like
/// its siblings** (`TencentQuoteProvider`/`TencentMinuteProvider` both take
/// `StockSymbol`): `StockSymbol` only accepts codes starting with
/// `0/3/4/6/8` — that's the existing watchlist/Watch UI's rule, and it's
/// left untouched per S1.1. `StockWorkspace` codes are resolved via
/// `ACodeResolver` instead (plan.md §0.5-3), which additionally covers
/// `5/9`-prefixed codes (ETFs, B-shares). Requiring a `StockSymbol` here
/// would silently re-introduce the exact gap `ACodeResolver` exists to
/// avoid. Callers resolve the symbol themselves — with
/// `ACodeResolver.fullSymbol(for:)` for `StockWorkspace` codes, or
/// `StockSymbol.fullSymbol` if they already have one.
public actor TencentDailyProvider: DailyBarsProvider {
    public init() {}

    public enum DailyBarsError: Error, LocalizedError {
        case badURL
        case networkError(Error)
        case emptyResponse(String)

        public var errorDescription: String? {
            switch self {
            case .badURL:
                return "Invalid URL for daily bars"
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .emptyResponse(let symbol):
                return "No daily bars returned for \(symbol)"
            }
        }
    }

    /// Fetches up to `lookback` most-recent qfq-adjusted daily bars,
    /// ascending by date (oldest first — same convention as the raw
    /// endpoint). Retries once after a 1s delay on failure (S5.3, mirroring
    /// the `fetchWithRetry` pattern already used on the Watch side for
    /// first-connection latency).
    ///
    /// - Parameters:
    ///   - fullSymbol: e.g. `"sh600519"`.
    ///   - start/end: `"yyyy-MM-dd"` bounds.
    ///   - lookback: caps how many bars the endpoint returns; 320 comfortably
    ///     covers the 120+ bars task.md S5.1 asks for, with room for the
    ///     technical indicators' warm-up window (`COMPUTE_WINDOW_BARS=120`,
    ///     plan.md §2.2) plus MA60.
    public func fetchDailyBars(
        fullSymbol: String,
        start: String,
        end: String,
        lookback: Int = 320
    ) async throws -> [DailyBar] {
        do {
            return try await fetchDailyBarsOnce(fullSymbol: fullSymbol, start: start, end: end, lookback: lookback)
        } catch {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s, matches existing Watch fetchWithRetry
            return try await fetchDailyBarsOnce(fullSymbol: fullSymbol, start: start, end: end, lookback: lookback)
        }
    }

    private func fetchDailyBarsOnce(
        fullSymbol: String,
        start: String,
        end: String,
        lookback: Int
    ) async throws -> [DailyBar] {
        let data = try await fetchJSON(fullSymbol: fullSymbol, start: start, end: end, lookback: lookback)
        let bars = parseBars(json: data, fullSymbol: fullSymbol)
        guard !bars.isEmpty else {
            throw DailyBarsError.emptyResponse(fullSymbol)
        }
        return bars
    }

    private func fetchJSON(fullSymbol: String, start: String, end: String, lookback: Int) async throws -> Data {
        let param = "\(fullSymbol),day,\(start),\(end),\(lookback),qfq"
        guard var components = URLComponents(string: "https://web.ifzq.gtimg.cn/appstock/app/fqkline/get") else {
            throw DailyBarsError.badURL
        }
        components.queryItems = [URLQueryItem(name: "param", value: param)]
        guard let url = components.url else {
            throw DailyBarsError.badURL
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 8

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return data
        } catch {
            throw DailyBarsError.networkError(error)
        }
    }

    /// Parses a Tencent `fqkline` response for one symbol. Exposed for
    /// fixture-based tests (same reasoning as
    /// `TencentQuoteProvider.parse`/`TencentMinuteProvider.parsePoints`).
    ///
    /// Response shape: `data.{fullSymbol}.qfqday` (falling back to `.day`),
    /// an array of `[date, open, close, high, low, volume, amount?]` rows.
    /// Parses defensively — bounds-checks row length and tolerates numbers
    /// arriving as either JSON numbers or numeric strings, since Tencent's
    /// kline endpoints are known to do either (plan.md §8/§16: field
    /// positions and encodings for these undocumented endpoints can shift).
    public nonisolated func parseBars(json data: Data, fullSymbol: String) -> [DailyBar] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataBlock = root["data"] as? [String: Any],
              let symbolBlock = dataBlock[fullSymbol] as? [String: Any] else {
            return []
        }

        let rawRows = (symbolBlock["qfqday"] as? [[Any]]) ?? (symbolBlock["day"] as? [[Any]]) ?? []

        return rawRows.compactMap { row -> DailyBar? in
            guard row.count >= 6,
                  let date = row[0] as? String,
                  let open = Self.number(row[1]),
                  let close = Self.number(row[2]),
                  let high = Self.number(row[3]),
                  let low = Self.number(row[4]),
                  let lots = Self.number(row[5]) else {
                return nil
            }
            let amount = row.count > 6 ? Self.number(row[6]) : nil
            return DailyBar(date: date, open: open, close: close, high: high, low: low, volume: lots * 100, amount: amount)
        }
    }

    private nonisolated static func number(_ value: Any) -> Double? {
        if let number = value as? Double {
            return number
        }
        if let number = value as? Int {
            return Double(number)
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }
}
