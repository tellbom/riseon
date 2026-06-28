import Foundation

/// Fetches A-share quotes from Tencent's unofficial public endpoint.
public actor TencentQuoteProvider: QuoteProvider {
    public init() {}

    public func fetchQuote(for symbol: StockSymbol) async throws -> Quote {
        let raw = try await fetchRaw(symbols: [symbol])
        guard let quote = parse(raw: raw, symbol: symbol) else {
            throw QuoteError.parseFailure(symbol.fullSymbol)
        }
        return quote
    }

    public enum QuoteError: Error, LocalizedError {
        case badURL
        case networkError(Error)
        case decodingError
        case parseFailure(String)

        public var errorDescription: String? {
            switch self {
            case .badURL:
                return "Invalid URL"
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .decodingError:
                return "Response decoding failed; expected GBK-compatible text"
            case .parseFailure(let symbol):
                return "Could not parse quote for \(symbol)"
            }
        }
    }

    private func fetchRaw(symbols: [StockSymbol]) async throws -> String {
        let joined = symbols.map(\.fullSymbol).joined(separator: ",")
        guard let url = URL(string: "https://qt.gtimg.cn/q=\(joined)") else {
            throw QuoteError.badURL
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw QuoteError.networkError(error)
        }

        let encoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringConvertIANACharSetNameToEncoding("GB18030" as CFString)
        )
        guard let text = String(data: data, encoding: String.Encoding(rawValue: encoding)) else {
            throw QuoteError.decodingError
        }

        return text
    }

    /// Parses a Tencent response for one symbol. Exposed for fixture-based tests.
    public nonisolated func parse(raw: String, symbol: StockSymbol) -> Quote? {
        let marker = "v_\(symbol.fullSymbol)=\""
        guard let markerRange = raw.range(of: marker),
              let payloadEnd = raw.range(of: "\"", range: markerRange.upperBound..<raw.endIndex) else {
            return nil
        }

        let payload = String(raw[markerRange.upperBound..<payloadEnd.lowerBound])
        let fields = payload.components(separatedBy: "~")

        func field(_ index: Int) -> String? {
            guard index < fields.count else {
                return nil
            }

            let value = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        guard
            let name = field(1),
            let price = field(3).flatMap(Double.init),
            let previousClose = field(4).flatMap(Double.init),
            let open = field(5).flatMap(Double.init),
            let changeAmount = field(31).flatMap(Double.init),
            let changePercent = field(32).flatMap(Double.init),
            let high = field(33).flatMap(Double.init),
            let low = field(34).flatMap(Double.init),
            let timestamp = field(30)
        else {
            return nil
        }

        return Quote(
            symbol: symbol,
            name: name,
            price: price,
            previousClose: previousClose,
            open: open,
            high: high,
            low: low,
            changeAmount: changeAmount,
            changePercent: changePercent,
            updatedAt: Self.parseTimestamp(timestamp) ?? Date(),
            orderBook: Self.parseOrderBook(field: field)
        )
    }

    private nonisolated static func parseOrderBook(field: (Int) -> String?) -> OrderBook? {
        let bidPairs = [(9, 10), (11, 12), (13, 14), (15, 16), (17, 18)]
        let askPairs = [(19, 20), (21, 22), (23, 24), (25, 26), (27, 28)]

        let bids = bidPairs.compactMap { priceIndex, volumeIndex in
            makeLevel(price: field(priceIndex), volume: field(volumeIndex))
        }
        let asks = askPairs.compactMap { priceIndex, volumeIndex in
            makeLevel(price: field(priceIndex), volume: field(volumeIndex))
        }

        guard !bids.isEmpty || !asks.isEmpty else {
            return nil
        }

        return OrderBook(bids: bids, asks: asks)
    }

    private nonisolated static func makeLevel(price: String?, volume: String?) -> Level? {
        guard let price = price.flatMap(Double.init),
              let volume = volume.flatMap(Int.init) else {
            return nil
        }

        return Level(price: price, volume: volume)
    }

    private nonisolated static func parseTimestamp(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.date(from: value)
    }
}
