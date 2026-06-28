import SwiftUI

struct StockDetailContainerView: View {
    let code: String

    private let symbol: StockSymbol

    @Environment(\.scenePhase) private var scenePhase
    @State private var loadedQuote: Quote?
    @State private var currentTab = 0

    init(code: String) {
        self.code = code
        self.symbol = StockSymbol(code: code)!
    }

    var body: some View {
        TabView(selection: $currentTab) {
            QuoteDetailView(
                code: code,
                onQuoteLoaded: { quote in
                    loadedQuote = quote
                }
            )
            .tag(0)

            MinuteChartView(symbol: symbol, loadedQuote: $loadedQuote)
                .tag(1)
        }
        .tabViewStyle(.page)
        .indexViewStyle(.page(backgroundDisplayMode: .automatic))
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                refreshActiveTab()
                startTimer(for: currentTab)
            case .inactive, .background:
                stopAllTimers()
            @unknown default:
                break
            }
        }
        .onChange(of: currentTab) { _, tab in
            stopAllTimers()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                startTimer(for: tab)
            }
        }
        .onAppear {
            startTimer(for: currentTab)
        }
        .onDisappear {
            stopAllTimers()
        }
    }

    private func refreshActiveTab() {
        NotificationCenter.default.post(name: .stockDetailRefreshPage0, object: nil)
        NotificationCenter.default.post(name: .stockDetailRefreshPage1, object: nil)
    }

    private func stopAllTimers() {
        NotificationCenter.default.post(name: .stockDetailStopPage0, object: nil)
        NotificationCenter.default.post(name: .stockDetailStopPage1, object: nil)
    }

    private func startTimer(for tab: Int) {
        NotificationCenter.default.post(name: tab == 0 ? .stockDetailStartPage0 : .stockDetailStartPage1, object: nil)
    }
}

extension Notification.Name {
    static let stockDetailRefreshPage0 = Notification.Name("stockDetail.refresh.page0")
    static let stockDetailRefreshPage1 = Notification.Name("stockDetail.refresh.page1")
    static let stockDetailStopPage0 = Notification.Name("stockDetail.stop.page0")
    static let stockDetailStopPage1 = Notification.Name("stockDetail.stop.page1")
    static let stockDetailStartPage0 = Notification.Name("stockDetail.start.page0")
    static let stockDetailStartPage1 = Notification.Name("stockDetail.start.page1")
}
