import SwiftUI

struct WatchlistView: View {
    @StateObject private var viewModel: WatchlistViewModel
    @State private var isAddingStock = false

    init(store: WatchlistStore) {
        _viewModel = StateObject(wrappedValue: WatchlistViewModel(store: store))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.codes.isEmpty {
                    emptyState
                } else {
                    stockList
                }
            }
            .navigationTitle("自选股")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isAddingStock = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加股票")
                }
            }
            .sheet(isPresented: $isAddingStock, onDismiss: viewModel.clearError) {
                AddStockView(viewModel: viewModel, isPresented: $isAddingStock)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "暂无自选股",
            systemImage: "chart.line.uptrend.xyaxis",
            description: Text("点击右上角添加按钮")
        )
        .accessibilityLabel("自选股列表为空")
    }

    private var stockList: some View {
        List {
            ForEach(viewModel.codes, id: \.self) { code in
                StockRowView(code: code)
                    .accessibilityLabel("股票代码 \(code)")
            }
            .onDelete(perform: viewModel.remove)
        }
        .accessibilityLabel("自选股列表")
    }
}

private struct StockRowView: View {
    let code: String

    var body: some View {
        HStack {
            Text(code)
                .font(.body.monospacedDigit())
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
                .imageScale(.small)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    WatchlistView(store: WatchlistStore(key: "preview_watchlist_codes"))
}
