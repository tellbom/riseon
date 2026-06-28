import SwiftUI

struct StockDetailContainerView: View {
    let code: String

    @State private var loadedQuote: Quote?

    var body: some View {
        TabView {
            QuoteDetailView(code: code) { quote in
                loadedQuote = quote
            }
            .tag(0)

            minuteChartPage
                .tag(1)
        }
        .tabViewStyle(.page)
        .indexViewStyle(.page(backgroundDisplayMode: .never))
    }

    @ViewBuilder
    private var minuteChartPage: some View {
        if let symbol = StockSymbol(code: code),
           let loadedQuote {
            MinuteChartView(symbol: symbol, previousClose: loadedQuote.previousClose)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "arrow.left.circle")
                    .foregroundStyle(.secondary)
                Text("请先加载行情")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
