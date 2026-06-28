import Foundation

public actor TencentMinuteProvider {
    public init() {}

    public func fetchMinuteData(for symbol: StockSymbol, previousClose: Double) async throws -> MinuteData {
        let data = try await fetchJSON(symbol: symbol)
        let points = parsePoints(json: data, symbol: symbol)
        return MinuteData(symbol: symbol, previousClose: previousClose, points: points)
    }

    public enum MinuteError: Error, LocalizedError {
        case badURL
        case networkError(Error)

        public var errorDescription: String? {
            switch self {
            case .badURL:
                return "Invalid URL for minute data"
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            }
        }
    }

    private func fetchJSON(symbol: StockSymbol) async throws -> Data {
        guard let url = URL(string: "https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=\(symbol.fullSymbol)") else {
            throw MinuteError.badURL
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 8

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return data
        } catch {
            throw MinuteError.networkError(error)
        }
    }

    public nonisolated func parsePoints(json data: Data, symbol: StockSymbol) -> [MinutePoint] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataBlock = root["data"] as? [String: Any],
              let symbolBlock = dataBlock[symbol.fullSymbol] as? [String: Any],
              let innerData = symbolBlock["data"] as? [String: Any],
              let rawPoints = innerData["data"] as? [String] else {
            return []
        }

        return rawPoints.compactMap { raw in
            let parts = raw.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let price = Double(parts[1]),
                  let cumulativeVolume = Int(parts[2]) else {
                return nil
            }

            let rawTime = String(parts[0])
            let index = Self.minuteIndex(from: rawTime)
            guard index >= 0 else {
                return nil
            }

            let avgPrice: Double
            if parts.count >= 4,
               let candidate = Double(parts[3]),
               candidate > 0,
               abs(candidate - price) / max(price, 0.01) < 0.2 {
                avgPrice = candidate
            } else {
                avgPrice = price
            }

            return MinutePoint(
                minuteIndex: index,
                time: Self.formatTime(rawTime),
                price: price,
                cumulativeVolume: cumulativeVolume,
                avgPrice: avgPrice
            )
        }
    }

    private nonisolated static func minuteIndex(from value: String) -> Int {
        guard value.count == 4,
              let hour = Int(value.prefix(2)),
              let minute = Int(value.suffix(2)) else {
            return -1
        }

        let total = hour * 60 + minute
        let morningOpen = 9 * 60 + 30
        let morningClose = 11 * 60 + 30
        let afternoonOpen = 13 * 60
        let afternoonClose = 15 * 60

        if total >= morningOpen && total <= morningClose {
            return total - morningOpen
        }

        if total >= afternoonOpen && total <= afternoonClose {
            return (morningClose - morningOpen) + (total - afternoonOpen)
        }

        return -1
    }

    private nonisolated static func formatTime(_ value: String) -> String {
        guard value.count == 4 else {
            return value
        }

        return "\(value.prefix(2)):\(value.suffix(2))"
    }
}
