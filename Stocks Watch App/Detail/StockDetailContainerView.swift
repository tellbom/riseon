// StockWatch Watch App/Detail/StockDetailContainerView.swift
//
// Manages the two-page detail screen and owns the auto-refresh lifecycle:
//
//   ┌─────────────────────────────────────────────────────────┐
//   │  watchOS lifecycle                                       │
//   │                                                         │
//   │  App enters foreground (.active)                        │
//   │    → immediate refresh() on the currently visible page  │
//   │                                                         │
//   │  App goes background (.inactive / .background)          │
//   │    → stopAutoRefresh() on both VMs                      │
//   │    → watchOS may suspend URLSession tasks anyway         │
//   │                                                         │
//   │  User swipes to page 1 (chart)                          │
//   │    → page-0 VM pauses (stopAutoRefresh)                 │
//   │    → page-1 VM resumes (startAutoRefresh)               │
//   │  and vice-versa — only the visible page polls.          │
//   └─────────────────────────────────────────────────────────┘
//
// Tab snap-back fix: MinuteChartView is always present in the TabView tree.
// Structural rebuilds are avoided by keeping loadedQuote in the Container
// and passing it as a Binding into MinuteChartView.

import SwiftUI

struct StockDetailContainerView: View {

    let code: String
    private let symbol: StockSymbol

    // Quote shared from page 0 → page 1 (previousClose for chart baseline)
    @State private var loadedQuote: Quote? = nil

    // Which tab is currently visible
    @State private var currentTab: Int = 0

    // Scene phase for foreground / background detection
    @Environment(\.scenePhase) private var scenePhase

    init(code: String) {
        self.code   = code
        self.symbol = StockSymbol(code: code)!
    }

    var body: some View {
        TabView(selection: $currentTab) {
            QuoteDetailView(
                code: code,
                onQuoteLoaded: { quote in loadedQuote = quote },
                onStartRefresh: { },    // timer managed by Container via onChange
                onStopRefresh:  { }
            )
            .tag(0)

            MinuteChartView(symbol: symbol, loadedQuote: $loadedQuote)
                .tag(1)
        }
        .tabViewStyle(.page)
        .indexViewStyle(.page(backgroundDisplayMode: .automatic))
        // ── Scene phase: pause/resume on background / foreground ──
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Came back to foreground — refresh immediately then restart timer
                refreshActiveTab()
            case .inactive, .background:
                stopAllTimers()
            @unknown default:
                break
            }
        }
        // ── Tab change: hand off the timer between pages ──
        .onChange(of: currentTab) { _, tab in
            stopAllTimers()
            // Small delay so the new page's onAppear fires first (VM is ready)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)  // 50 ms
                startTimer(for: tab)
            }
        }
        .onDisappear {
            stopAllTimers()
        }
    }

    // MARK: — Helpers

    private func refreshActiveTab() {
        let name: Notification.Name = currentTab == 0
            ? .stockDetailRefreshPage0
            : .stockDetailRefreshPage1
        NotificationCenter.default.post(name: name, object: nil)
    }

    private func stopAllTimers() {
        NotificationCenter.default.post(name: .stockDetailStopPage0, object: nil)
        NotificationCenter.default.post(name: .stockDetailStopPage1, object: nil)
    }

    private func startTimer(for tab: Int) {
        let name: Notification.Name = tab == 0
            ? .stockDetailStartPage0
            : .stockDetailStartPage1
        NotificationCenter.default.post(name: name, object: nil)
    }
}

// MARK: — Notification names (avoids string literals)

extension Notification.Name {
    static let stockDetailRefreshPage0 = Notification.Name("stockDetail.refresh.page0")
    static let stockDetailRefreshPage1 = Notification.Name("stockDetail.refresh.page1")
    static let stockDetailStopPage0    = Notification.Name("stockDetail.stop.page0")
    static let stockDetailStopPage1    = Notification.Name("stockDetail.stop.page1")
    static let stockDetailStartPage0   = Notification.Name("stockDetail.start.page0")
    static let stockDetailStartPage1   = Notification.Name("stockDetail.start.page1")
}
