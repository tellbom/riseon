import Combine
import Foundation

@MainActor
final class QuoteDetailViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(Quote)
        case error(String)
    }

    @Published private(set) var state: LoadState = .idle

    let symbol: StockSymbol
    let refreshInterval: TimeInterval

    private let provider: any QuoteProvider
    private var timer: Timer?

    init(symbol: StockSymbol, provider: any QuoteProvider, refreshInterval: TimeInterval = 10) {
        self.symbol = symbol
        self.provider = provider
        self.refreshInterval = refreshInterval
    }

    func refresh() {
        if case .loading = state {
            return
        }

        if case .loaded = state {
            // Keep stale data visible while refreshing.
        } else {
            state = .loading
        }

        Task {
            await fetchOnce()
        }
    }

    func startAutoRefresh() {
        guard timer == nil else {
            return
        }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
    }

    private func fetchOnce() async {
        do {
            let quote = try await provider.fetchQuote(for: symbol)
            state = .loaded(quote)
        } catch {
            if case .loaded = state {
                // Preserve the last successful quote during transient failures.
            } else {
                state = .error(error.localizedDescription)
            }
        }
    }

    deinit {
        timer?.invalidate()
    }
}
