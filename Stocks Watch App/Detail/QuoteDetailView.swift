// StockWatch Watch App/Detail/QuoteDetailView.swift
//
// Auto-refresh: timer started via Notification from StockDetailContainerView.
// Stale data is preserved during background refresh — the screen never blanks.

import SwiftUI

struct QuoteDetailView: View {

    let code: String
    var onQuoteLoaded:  ((Quote) -> Void)? = nil
    var onStartRefresh: (() -> Void)?      = nil   // unused, kept for API compat
    var onStopRefresh:  (() -> Void)?      = nil

    @StateObject private var viewModel: QuoteDetailViewModel

    init(code: String,
         onQuoteLoaded:  ((Quote) -> Void)? = nil,
         onStartRefresh: (() -> Void)?      = nil,
         onStopRefresh:  (() -> Void)?      = nil) {
        self.code           = code
        self.onQuoteLoaded  = onQuoteLoaded
        self.onStartRefresh = onStartRefresh
        self.onStopRefresh  = onStopRefresh
        let symbol = StockSymbol(code: code)!
        _viewModel = StateObject(
            wrappedValue: QuoteDetailViewModel(
                symbol:   symbol,
                provider: TencentQuoteProvider()
            )
        )
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle:
                Color.clear

            case .loading:
                // Show spinner only on very first load
                loadingView

            case .loaded(let quote):
                quoteScrollView(quote)
                    .onAppear { onQuoteLoaded?(quote) }

            case .error(let message):
                errorView(message)
            }
        }
        .navigationTitle(code)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: viewModel.state) { _, newState in
            if case .loaded(let q) = newState { onQuoteLoaded?(q) }
        }
        // ── Auto-refresh lifecycle via notifications ──
        .onDisappear { viewModel.stopAutoRefresh() }
        .onReceive(NotificationCenter.default.publisher(for: .stockDetailRefreshPage0)) { _ in
            viewModel.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockDetailStartPage0)) { _ in
            viewModel.startAutoRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockDetailStopPage0)) { _ in
            viewModel.stopAutoRefresh()
        }
    }

    // MARK: — State views

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("加载中…")
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
            Button("重试") { viewModel.startAutoRefresh() }
                .buttonStyle(.bordered)
                .tint(.blue)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("加载失败，\(message)，点击重试")
    }

    private func quoteScrollView(_ quote: Quote) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // ── Refresh indicator ──
                refreshBadge
                headerSection(quote)
                Divider().padding(.vertical, 6)
                coreFieldsSection(quote)
                if let book = quote.orderBook {
                    Divider().padding(.vertical, 6)
                    orderBookSection(book)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // ── Auto-refresh badge (small, non-intrusive) ──
    private var refreshBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(.green)
                .frame(width: 5, height: 5)
            Text("自动刷新 · 每3秒")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            Spacer()
            Text(Date(), style: .time)
                .font(.system(size: 8).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    // MARK: — Quote sections

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
            FieldRow(label: "涨跌", value: quote.changeAmount.changeAmountFormatted,
                     valueColor: quote.changeColor)
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
            ForEach(book.asks.indices.reversed(), id: \.self) { i in
                BookRow(label: "卖\(i + 1)", price: book.asks[i].price,
                        volume: book.asks[i].volume, side: .ask)
            }
            Divider()
            ForEach(book.bids.indices, id: \.self) { i in
                BookRow(label: "买\(i + 1)", price: book.bids[i].price,
                        volume: book.bids[i].volume, side: .bid)
            }
        }
        .accessibilityLabel("委托明细，\(book.bids.count)档买盘，\(book.asks.count)档卖盘")
    }
}

// MARK: — Reusable rows

private struct FieldRow: View {
    let label: String; let value: String; var valueColor: Color = .primary
    var body: some View {
        HStack {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
            Spacer()
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(valueColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value)")
    }
}

private enum BookSide { case bid, ask }

private struct BookRow: View {
    let label: String; let price: Double; let volume: Int; let side: BookSide
    private var sideColor: Color { side == .bid ? .red : .green }
    var body: some View {
        HStack {
            Text(label).font(.caption2).foregroundStyle(sideColor).frame(width: 28, alignment: .leading)
            Spacer()
            Text(price.priceFormatted).font(.caption2.monospacedDigit()).foregroundStyle(sideColor)
            Text("\(volume)手").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)，价格 \(price.priceFormatted)，数量 \(volume) 手")
    }
}

// MARK: — Formatting

private extension Double {
    var priceFormatted: String      { String(format: "%.2f", self) }
    var changeAmountFormatted: String {
        (self >= 0 ? "+" : "") + String(format: "%.2f", self)
    }
    var changePercentFormatted: String {
        (self >= 0 ? "+" : "") + String(format: "%.2f", self) + "%"
    }
}
private extension Date {
    var timeFormatted: String {
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"
        fmt.timeZone = TimeZone(identifier: "Asia/Shanghai"); return fmt.string(from: self)
    }
}
private extension Quote {
    var changeColor: Color {
        if changePercent > 0 { return .red }
        if changePercent < 0 { return .green }
        return .primary
    }
}
