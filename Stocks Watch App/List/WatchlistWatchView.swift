import SwiftUI

struct WatchlistWatchView: View {
    @ObservedObject var store: WatchlistStore

    var body: some View {
        NavigationStack {
            Group {
                if store.codes.isEmpty {
                    emptyState
                } else {
                    stockList
                }
            }
            .navigationTitle("自选股")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("暂无自选股")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("自选股列表为空，请在 iPhone 上添加")
    }

    private var stockList: some View {
        List(store.codes, id: \.self) { code in
            NavigationLink {
                QuoteDetailView(code: code)
            } label: {
                Text(code)
                    .font(.body.monospacedDigit())
            }
            .accessibilityLabel("查看股票 \(code) 行情")
        }
    }
}
