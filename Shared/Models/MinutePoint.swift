import Foundation

public struct MinutePoint: Identifiable, Hashable, Sendable {
    public nonisolated var id: Int { minuteIndex }

    public let minuteIndex: Int
    public let time: String
    public let price: Double
    public let cumulativeVolume: Int
    public let avgPrice: Double

    public nonisolated init(minuteIndex: Int, time: String, price: Double, cumulativeVolume: Int, avgPrice: Double) {
        self.minuteIndex = minuteIndex
        self.time = time
        self.price = price
        self.cumulativeVolume = cumulativeVolume
        self.avgPrice = avgPrice
    }
}

public struct MinuteData: Hashable, Sendable {
    public let symbol: StockSymbol
    public let previousClose: Double
    public let points: [MinutePoint]

    public nonisolated init(symbol: StockSymbol, previousClose: Double, points: [MinutePoint]) {
        self.symbol = symbol
        self.previousClose = previousClose
        self.points = points
    }
}
