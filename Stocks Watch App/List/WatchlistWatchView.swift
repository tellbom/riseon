import SwiftUI

struct WatchlistWatchView: View {
    @ObservedObject var store: WatchlistStore

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
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
        List(store.items) { item in
            NavigationLink {
                StockDetailContainerView(code: item.code)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    if !item.name.isEmpty {
                        Text(item.name)
                            .lineLimit(1)
                    }
                    Text(item.code)
                        .font(item.name.isEmpty ? .body.monospacedDigit() : .caption.monospacedDigit())
                        .foregroundStyle(item.name.isEmpty ? .primary : .secondary)
                }
            }
            .accessibilityLabel("查看 \(item.name.isEmpty ? item.code : item.name) 行情")
        }
    }
}
