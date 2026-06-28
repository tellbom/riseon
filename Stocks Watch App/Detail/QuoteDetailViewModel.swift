import Combine
import Foundation

@MainActor
final class QuoteDetailViewModel: ObservableObject {
    enum LoadState {
        case idle
        case loading
        case loaded(Quote)
        case error(String)
    }

    @Published private(set) var state: LoadState = .idle

    let symbol: StockSymbol

    private let provider: any QuoteProvider

    init(symbol: StockSymbol, provider: any QuoteProvider) {
        self.symbol = symbol
        self.provider = provider
    }

    func refresh() {
        if case .loading = state {
            return
        }

        state = .loading

        Task {
            do {
                let quote = try await provider.fetchQuote(for: symbol)
                state = .loaded(quote)
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }
}
