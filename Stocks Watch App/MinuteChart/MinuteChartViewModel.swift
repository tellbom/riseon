import Combine
import Foundation

@MainActor
final class MinuteChartViewModel: ObservableObject {
    enum LoadState {
        case idle
        case loading
        case loaded(MinuteData)
        case error(String)
    }

    @Published private(set) var state: LoadState = .idle

    let symbol: StockSymbol

    private let previousClose: Double
    private let minuteProvider = TencentMinuteProvider()

    init(symbol: StockSymbol, previousClose: Double) {
        self.symbol = symbol
        self.previousClose = previousClose
    }

    func refresh() {
        if case .loading = state {
            return
        }

        state = .loading

        Task {
            do {
                let data = try await minuteProvider.fetchMinuteData(for: symbol, previousClose: previousClose)
                state = data.points.isEmpty ? .error("暂无分时数据") : .loaded(data)
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }
}
