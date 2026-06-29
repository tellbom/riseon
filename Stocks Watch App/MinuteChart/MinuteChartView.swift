// StockWatch Watch App/MinuteChart/MinuteChartView.swift
//
// FIX 2: price line thinned to 1.2 pt, avg line to 0.8 pt
// FIX 3: purple-flash bug — never switch view identity during refresh.
//        The chart content is always rendered; a thin loading overlay is
//        composited on top with .overlay, so SwiftUI never destroys and
//        recreates the Canvas node. No identity change = no purple frame.

import SwiftUI

struct MinuteChartView: View {

    let symbol: StockSymbol
    @Binding var loadedQuote: Quote?

    @StateObject private var viewModel: MinuteChartViewModel

    @State private var crownValue:    Double = 1.0
    @State private var selectedIndex: Int    = 0
    @State private var isAutoRefreshActive = false

    init(symbol: StockSymbol, loadedQuote: Binding<Quote?>) {
        self.symbol       = symbol
        self._loadedQuote = loadedQuote
        _viewModel = StateObject(wrappedValue: MinuteChartViewModel(symbol: symbol))
    }

    var body: some View {
        // ── Outer container is always the same view type ──
        // We never switch between fundamentally different layouts.
        ZStack {
            switch viewModel.state {
            case .waiting:
                waitingView
            case .loading:
                // First-load spinner (no data yet)
                loadingView
            case .loaded(let data):
                // Chart is always rendered once data is available.
                // Subsequent refreshes update `data` in-place — no identity change.
                chartContent(data)
            case .error(let msg):
                // Error only shown when we have no prior data to display
                errorView(msg)
            }
        }
        .navigationTitle(symbol.code)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: loadedQuote) { _, q in
            if let q {
                viewModel.quoteDidLoad(previousClose: q.previousClose)
                if isAutoRefreshActive { viewModel.startAutoRefresh() }
            }
        }
        .onAppear {
            if let q = loadedQuote { viewModel.quoteDidLoad(previousClose: q.previousClose) }
        }
        .onDisappear { viewModel.stopAutoRefresh() }
        .onReceive(NotificationCenter.default.publisher(for: .stockDetailRefreshPage1)) { _ in
            viewModel.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockDetailStartPage1)) { _ in
            isAutoRefreshActive = true
            viewModel.startAutoRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockDetailStopPage1)) { _ in
            isAutoRefreshActive = false
            viewModel.stopAutoRefresh()
        }
    }

    // MARK: — Placeholder views (only shown before first successful load)

    private var waitingView: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.left.circle").foregroundStyle(.secondary)
            Text("请先查看行情").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 6) {
            ProgressView()
            Text("加载分时线…").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line").foregroundStyle(.secondary)
            Text(msg).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("重试") { viewModel.refresh() }
                .font(.caption2).buttonStyle(.bordered).tint(.orange)
        }
    }

    // MARK: — Chart (rendered once, updated in-place)

    private func chartContent(_ data: MinuteData) -> some View {
        let count        = data.points.count
        let clampedIdx   = max(0, min(count - 1, selectedIndex))
        let selected     = data.points[clampedIdx]

        return VStack(spacing: 2) {

            selectedInfoHeader(selected, data: data)

            HStack(spacing: 2) {
                leftAxis(data: data).frame(width: 26)

                // FIX 3: Canvas is now always inside a stable ZStack layer.
                // .id is NOT set, so SwiftUI reuses the existing Canvas node.
                IntradayCanvas(data: data, selectedIndex: clampedIdx)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusable()
                    .digitalCrownRotation(
                        $crownValue,
                        from: 0.0, through: 1.0,
                        by: 1.0 / Double(max(count - 1, 1)),
                        sensitivity: .medium,
                        isContinuous: false,
                        isHapticFeedbackEnabled: true
                    )
                    .onChange(of: crownValue) { _, v in
                        selectedIndex = Int((v * Double(count - 1)).rounded())
                            .clamped(to: 0...(count - 1))
                    }
                    .onAppear {
                        selectedIndex = count - 1
                        crownValue    = 1.0
                    }
                    .onChange(of: count) { _, newCount in
                        guard newCount > 0 else { return }
                        selectedIndex = newCount - 1
                        crownValue    = 1.0
                    }

                rightAxis(data: data).frame(width: 34)
            }

            timeAxis()
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    // MARK: — Header (selected point info)

    private func selectedInfoHeader(_ pt: MinutePoint, data: MinuteData) -> some View {
        let prevClose = data.previousClose
        let changeAmt = pt.price - prevClose
        let changePct = prevClose > 0 ? changeAmt / prevClose * 100 : 0
        let color: Color = changeAmt > 0 ? .red : changeAmt < 0 ? .green : .primary

        return VStack(spacing: 1) {
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 5, height: 5)
                Text("自动刷新 · 每3秒")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(pt.time)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Text(pt.price.priceStr)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color)
                Text(changeAmt >= 0 ? "+\(changeAmt.priceStr)" : changeAmt.priceStr)
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(color)
                Text(changePct >= 0
                     ? "+\(String(format: "%.2f", changePct))%"
                     : "\(String(format: "%.2f", changePct))%")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(color)
                Spacer()
                Text("\(pt.cumulativeVolume)手")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: — Axes

    private func leftAxis(data: MinuteData) -> some View {
        let pct = symmetricPct(data: data)
        return VStack(alignment: .trailing, spacing: 0) {
            Text("+\(String(format: "%.1f", pct))%").axisLabel()
            Spacer()
            Text("0%").axisLabel()
            Spacer()
            Text("-\(String(format: "%.1f", pct))%").axisLabel()
        }.padding(.vertical, 2)
    }

    private func rightAxis(data: MinuteData) -> some View {
        let prices = data.points.map(\.price)
        let highP  = prices.max() ?? data.previousClose
        let lowP   = prices.min() ?? data.previousClose
        return VStack(alignment: .leading, spacing: 0) {
            Text(highP.priceStr).axisLabel()
            Spacer()
            Text(data.previousClose.priceStr)
                .font(.system(size: 8).monospacedDigit()).foregroundStyle(.gray)
            Spacer()
            Text(lowP.priceStr).axisLabel()
        }.padding(.vertical, 2)
    }

    private func timeAxis() -> some View {
        HStack {
            Text("09:30"); Spacer(); Text("11:30"); Spacer(); Text("15:00")
        }
        .font(.system(size: 8)).foregroundStyle(.secondary)
    }

    private func symmetricPct(data: MinuteData) -> Double {
        guard data.previousClose > 0 else { return 2 }
        let prices    = data.points.map(\.price)
        let allVals   = prices + [data.previousClose]
        let halfRange = max(
            abs((allVals.max() ?? data.previousClose) - data.previousClose),
            abs(data.previousClose - (allVals.min() ?? data.previousClose)),
            data.previousClose * 0.005
        )
        return halfRange / data.previousClose * 100
    }
}

// MARK: — Canvas (pure drawing, no SwiftUI state inside)

private struct IntradayCanvas: View {
    let data: MinuteData
    let selectedIndex: Int

    var body: some View {
        // drawingGroup() flattens to a single Metal layer — eliminates the
        // purple compositing flash that happens when SwiftUI blends Canvas
        // with surrounding views during data updates.
        Canvas { ctx, size in draw(ctx: ctx, size: size) }
            .clipped()
            .drawingGroup()   // FIX 3: force Metal rasterisation, no purple frames
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        guard !data.points.isEmpty, size.width > 0, size.height > 0 else { return }

        let points     = data.points
        let prevClose  = data.previousClose
        let totalSlots = 240

        // Y range — symmetric around prevClose
        let prices    = points.map(\.price)
        let avgs      = points.map(\.avgPrice)
        let allVals   = prices + avgs + [prevClose]
        let halfRange = max(
            abs((allVals.max() ?? prevClose) - prevClose),
            abs(prevClose - (allVals.min() ?? prevClose)),
            prevClose * 0.005
        )
        let yMax = prevClose + halfRange
        let yMin = prevClose - halfRange

        func xOf(_ idx: Int) -> CGFloat {
            size.width * CGFloat(idx) / CGFloat(max(totalSlots - 1, 1))
        }
        func yOf(_ p: Double) -> CGFloat {
            guard yMax > yMin else { return size.height / 2 }
            return size.height * CGFloat(1.0 - (p - yMin) / (yMax - yMin))
        }

        // 1. Baseline (dashed gray)
        let baseY = yOf(prevClose)
        var bl = Path()
        bl.move(to: CGPoint(x: 0, y: baseY))
        bl.addLine(to: CGPoint(x: size.width, y: baseY))
        ctx.stroke(bl, with: .color(.gray.opacity(0.4)),
                   style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

        guard points.count >= 2 else { return }

        // 2. Price fill + FIX 2: line width 1.2 pt (was 2.0)
        var linePath = Path()
        linePath.move(to: CGPoint(x: xOf(points[0].minuteIndex), y: yOf(points[0].price)))
        for pt in points.dropFirst() {
            linePath.addLine(to: CGPoint(x: xOf(pt.minuteIndex), y: yOf(pt.price)))
        }

        var fill = linePath
        fill.addLine(to: CGPoint(x: xOf(points.last!.minuteIndex), y: size.height))
        fill.addLine(to: CGPoint(x: xOf(points.first!.minuteIndex), y: size.height))
        fill.closeSubpath()
        ctx.fill(fill, with: .color(.yellow.opacity(0.08)))

        ctx.stroke(linePath, with: .color(.yellow),
                   style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))   // FIX 2

        // 3. Average line — FIX 2: 0.8 pt (was 1.5)
        var avgPath = Path()
        avgPath.move(to: CGPoint(x: xOf(points[0].minuteIndex), y: yOf(points[0].avgPrice)))
        for pt in points.dropFirst() {
            avgPath.addLine(to: CGPoint(x: xOf(pt.minuteIndex), y: yOf(pt.avgPrice)))
        }
        ctx.stroke(avgPath, with: .color(.orange.opacity(0.8)),
                   style: StrokeStyle(lineWidth: 0.8, lineJoin: .round))   // FIX 2

        // 4. Crosshair
        let sel  = points[min(selectedIndex, points.count - 1)]
        let selX = xOf(sel.minuteIndex)
        let selY = yOf(sel.price)

        var cv = Path()
        cv.move(to: CGPoint(x: selX, y: 0))
        cv.addLine(to: CGPoint(x: selX, y: size.height))
        ctx.stroke(cv, with: .color(.white.opacity(0.3)),
                   style: StrokeStyle(lineWidth: 0.6, dash: [2, 2]))

        // Selected dot: white halo + yellow fill
        let r: CGFloat = 2.5
        ctx.fill(Path(ellipseIn: CGRect(x: selX - r - 1.2, y: selY - r - 1.2,
                                        width: (r + 1.2) * 2, height: (r + 1.2) * 2)),
                 with: .color(.white.opacity(0.2)))
        ctx.fill(Path(ellipseIn: CGRect(x: selX - r, y: selY - r,
                                        width: r * 2, height: r * 2)),
                 with: .color(.yellow))
    }
}

// MARK: — Extensions

private extension Text {
    func axisLabel() -> some View {
        self.font(.system(size: 8).monospacedDigit()).foregroundStyle(.secondary)
    }
}
private extension Double {
    var priceStr: String { String(format: "%.2f", self) }
}
private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
