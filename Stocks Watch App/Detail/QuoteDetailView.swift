import SwiftUI

struct QuoteDetailView: View {
    let code: String

    @StateObject private var viewModel: QuoteDetailViewModel

    init(code: String) {
        self.code = code
        let symbol = StockSymbol(code: code)!
        _viewModel = StateObject(
            wrappedValue: QuoteDetailViewModel(
                symbol: symbol,
                provider: TencentQuoteProvider()
            )
        )
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle:
                Color.clear
                    .task {
                        viewModel.refresh()
                    }
            case .loading:
                loadingView
            case .loaded(let quote):
                quoteScrollView(quote)
            case .error(let message):
                errorView(message)
            }
        }
        .navigationTitle(code)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("加载中...")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("正在加载行情数据")
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.yellow)
            Text("加载失败")
                .font(.caption)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button {
                viewModel.refresh()
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("加载失败，\(message)，点击重试")
    }

    private func quoteScrollView(_ quote: Quote) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection(quote)
                Divider().padding(.vertical, 6)
                coreFieldsSection(quote)

                if let book = quote.orderBook {
                    Divider().padding(.vertical, 6)
                    orderBookSection(book)
                }

                refreshButton
            }
            .padding(.horizontal, 4)
        }
    }

    private func headerSection(_ quote: Quote) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(quote.name)
                .font(.headline)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(quote.price.priceFormatted)
                    .font(.title3.monospacedDigit().bold())
                    .foregroundStyle(quote.changeColor)

                Text(quote.changePercent.changePercentFormatted)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(quote.changeColor)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(quote.name)，现价 \(quote.price.priceFormatted)，涨跌幅 \(quote.changePercent.changePercentFormatted)"
        )
    }

    private func coreFieldsSection(_ quote: Quote) -> some View {
        VStack(spacing: 4) {
            FieldRow(label: "代码", value: quote.symbol.code)
            FieldRow(
                label: "涨跌",
                value: quote.changeAmount.changeAmountFormatted,
                valueColor: quote.changeColor
            )
            FieldRow(label: "今开", value: quote.open.priceFormatted)
            FieldRow(label: "最高", value: quote.high.priceFormatted)
            FieldRow(label: "最低", value: quote.low.priceFormatted)
            FieldRow(label: "时间", value: quote.updatedAt.timeFormatted)
        }
    }

    private func orderBookSection(_ book: OrderBook) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("委托明细")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            ForEach(book.asks.indices.reversed(), id: \.self) { index in
                BookRow(
                    label: "卖\(index + 1)",
                    price: book.asks[index].price,
                    volume: book.asks[index].volume,
                    side: .ask
                )
            }

            Divider()

            ForEach(book.bids.indices, id: \.self) { index in
                BookRow(
                    label: "买\(index + 1)",
                    price: book.bids[index].price,
                    volume: book.bids[index].volume,
                    side: .bid
                )
            }
        }
        .accessibilityLabel("委托明细，\(book.bids.count)档买盘，\(book.asks.count)档卖盘")
    }

    private var refreshButton: some View {
        Button {
            viewModel.refresh()
        } label: {
            Label("刷新", systemImage: "arrow.clockwise")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .accessibilityLabel("手动刷新行情")
    }
}

private struct FieldRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(valueColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value)")
    }
}

private enum BookSide {
    case bid
    case ask
}

private struct BookRow: View {
    let label: String
    let price: Double
    let volume: Int
    let side: BookSide

    private var sideColor: Color {
        side == .bid ? .red : .green
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundStyle(sideColor)
                .frame(width: 28, alignment: .leading)
            Spacer()
            Text(price.priceFormatted)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(sideColor)
            Text("\(volume)手")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)，价格 \(price.priceFormatted)，数量 \(volume) 手")
    }
}

private extension Double {
    var priceFormatted: String {
        String(format: "%.2f", self)
    }

    var changeAmountFormatted: String {
        let sign = self >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", self))"
    }

    var changePercentFormatted: String {
        let sign = self >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", self))%"
    }
}

private extension Date {
    var timeFormatted: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.string(from: self)
    }
}

private extension Quote {
    var changeColor: Color {
        if changePercent > 0 {
            return .red
        }
        if changePercent < 0 {
            return .green
        }
        return .primary
    }
}
