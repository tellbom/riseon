import Foundation

/// One price and volume entry in the level-1 order book.
public struct Level: Hashable, Codable, Sendable {
    public let price: Double
    public let volume: Int

    public init(price: Double, volume: Int) {
        self.price = price
        self.volume = volume
    }
}

/// Up to five bid levels and five ask levels.
public struct OrderBook: Hashable, Codable, Sendable {
    public let bids: [Level]
    public let asks: [Level]

    public init(bids: [Level], asks: [Level]) {
        self.bids = bids
        self.asks = asks
    }
}

/// A full quote snapshot for one stock.
public struct Quote: Hashable, Codable, Sendable {
    public let symbol: StockSymbol
    public let name: String
    public let price: Double
    public let previousClose: Double
    public let open: Double
    public let high: Double
    public let low: Double
    public let changeAmount: Double
    public let changePercent: Double
    public let updatedAt: Date
    public let orderBook: OrderBook?

    public init(
        symbol: StockSymbol,
        name: String,
        price: Double,
        previousClose: Double,
        open: Double,
        high: Double,
        low: Double,
        changeAmount: Double,
        changePercent: Double,
        updatedAt: Date,
        orderBook: OrderBook?
    ) {
        self.symbol = symbol
        self.name = name
        self.price = price
        self.previousClose = previousClose
        self.open = open
        self.high = high
        self.low = low
        self.changeAmount = changeAmount
        self.changePercent = changePercent
        self.updatedAt = updatedAt
        self.orderBook = orderBook
    }
}
