import SwiftUI

/// Home list scaffold for the StockWorkspace feature (plan.md §4.1).
///
/// S1 scope only: reads the existing watchlist so the new `UI/` group has a
/// working, previewable view. Quote/change% and Workspace status badges are
/// added once `QuoteProvider` wiring (S5) and `StockWorkspace` (S2-S4) exist —
/// intentionally left out here to avoid getting ahead of those tasks.
struct HomeListView: View {
    @StateObject private var viewModel: WatchlistViewModel

    init(store: WatchlistStore) {
        _viewModel = StateObject(wrappedValue: WatchlistViewModel(store: store))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.items.isEmpty {
                    emptyState
                } else {
                    stockList
                }
            }
            .navigationTitle("个股问答")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "暂无自选股",
            systemImage: "chart.line.uptrend.xyaxis",
            description: Text("先在自选股中添加股票，即可在这里创建问答 Workspace")
        )
        .accessibilityLabel("首页列表为空")
    }

    private var stockList: some View {
        List(viewModel.items) { item in
            HomeStockRowView(item: item)
                .accessibilityLabel("\(item.name.isEmpty ? item.code : item.name)，代码 \(item.code)")
        }
        .accessibilityLabel("首页股票列表")
    }
}

private struct HomeStockRowView: View {
    let item: WatchlistItem

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if !item.name.isEmpty {
                    Text(item.name)
                }
                Text(item.code)
                    .font(item.name.isEmpty ? .body.monospacedDigit() : .caption.monospacedDigit())
                    .foregroundStyle(item.name.isEmpty ? .primary : .secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
                .imageScale(.small)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    HomeListView(store: WatchlistStore(key: "preview_workspace_home"))
}
