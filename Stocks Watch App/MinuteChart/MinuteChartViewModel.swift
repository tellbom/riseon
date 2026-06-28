import Combine
import Foundation

@MainActor
final class MinuteChartViewModel: ObservableObject {
    enum LoadState: Equatable {
        case waiting
        case loading
        case loaded(MinuteData)
        case error(String)
    }

    @Published private(set) var state: LoadState = .waiting

    let symbol: StockSymbol
    let refreshInterval: TimeInterval

    private var previousClose: Double?
    private let minuteProvider = TencentMinuteProvider()
    private var timer: Timer?

    init(symbol: StockSymbol, refreshInterval: TimeInterval = 15) {
        self.symbol = symbol
        self.refreshInterval = refreshInterval
    }

    func quoteDidLoad(previousClose: Double) {
        self.previousClose = previousClose
        if case .waiting = state {
            startAutoRefresh()
        }
    }

    func startAutoRefresh() {
        guard previousClose != nil, timer == nil else {
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

    func refresh() {
        guard let previousClose else {
            return
        }

        if case .loading = state {
            return
        }

        if case .loaded = state {
            // Keep stale data visible while refreshing.
        } else {
            state = .loading
        }

        Task {
            await fetchOnce(previousClose: previousClose)
        }
    }

    private func fetchOnce(previousClose: Double) async {
        do {
            let data = try await minuteProvider.fetchMinuteData(for: symbol, previousClose: previousClose)
            if data.points.isEmpty {
                if case .loaded = state {
                    // Keep stale chart visible.
                } else {
                    state = .error("暂无分时数据")
                }
            } else {
                state = .loaded(data)
            }
        } catch {
            if case .loaded = state {
                // Preserve the last successful chart during transient failures.
            } else {
                state = .error(error.localizedDescription)
            }
        }
    }

    deinit {
        timer?.invalidate()
    }
}
