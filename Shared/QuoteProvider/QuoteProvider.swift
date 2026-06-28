import Foundation

/// Fetches market-data snapshots behind a replaceable boundary.
public protocol QuoteProvider: Sendable {
    func fetchQuote(for symbol: StockSymbol) async throws -> Quote
}
