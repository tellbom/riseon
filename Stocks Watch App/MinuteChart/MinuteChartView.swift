import SwiftUI

struct MinuteChartView: View {
    let symbol: StockSymbol

    @Binding var loadedQuote: Quote?
    @StateObject private var viewModel: MinuteChartViewModel

    @State private var crownValue = 1.0
    @State private var selectedIndex = 0

    init(symbol: StockSymbol, loadedQuote: Binding<Quote?>) {
        self.symbol = symbol
        _loadedQuote = loadedQuote
        _viewModel = StateObject(wrappedValue: MinuteChartViewModel(symbol: symbol))
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .waiting:
                waitingView
            case .loading:
                loadingView
            case .loaded(let data):
                chartPage(data)
            case .error(let message):
                errorView(message)
            }
        }
        .navigationTitle(symbol.code)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: loadedQuote) { _, quote in
            if let quote {
                viewModel.quoteDidLoad(previousClose: quote.previousClose)
            }
        }
        .onAppear {
            if let loadedQuote {
                viewModel.quoteDidLoad(previousClose: loadedQuote.previousClose)
            }
            viewModel.startAutoRefresh()
        }
        .onDisappear {
            viewModel.stopAutoRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockDetailRefreshPage1)) { _ in
            viewModel.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockDetailStartPage1)) { _ in
            viewModel.startAutoRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockDetailStopPage1)) { _ in
            viewModel.stopAutoRefresh()
        }
    }

    private var waitingView: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.left.circle")
                .foregroundStyle(.secondary)
            Text("请先查看行情")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 6) {
            ProgressView()
            Text("加载分时线...")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试") {
                viewModel.refresh()
            }
            .font(.caption2)
            .buttonStyle(.bordered)
        }
    }

    private func chartPage(_ data: MinuteData) -> some View {
        let count = data.points.count
        let clampedIndex = max(0, min(count - 1, selectedIndex))
        let selected = data.points[clampedIndex]

        return VStack(spacing: 2) {
            selectedInfoHeader(selected, data: data)

            HStack(spacing: 2) {
                leftAxis(data: data)
                    .frame(width: 26)

                IntradayCanvas(data: data, selectedIndex: clampedIndex)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusable()
                    .digitalCrownRotation(
                        $crownValue,
                        from: 0.0,
                        through: 1.0,
                        by: 1.0 / Double(max(count - 1, 1)),
                        sensitivity: .medium,
                        isContinuous: false,
                        isHapticFeedbackEnabled: true
                    )
                    .onChange(of: crownValue) { _, value in
                        selectedIndex = Int((value * Double(count - 1)).rounded()).clamped(to: 0...(count - 1))
                    }
                    .onAppear {
                        selectedIndex = count - 1
                        crownValue = 1.0
                    }
                    .onChange(of: data.points.count) { _, newCount in
                        if newCount > 0 {
                            selectedIndex = newCount - 1
                            crownValue = 1.0
                        }
                    }

                rightAxis(data: data)
                    .frame(width: 34)
            }

            timeAxis
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    private func selectedInfoHeader(_ point: MinutePoint, data: MinuteData) -> some View {
        let previousClose = data.previousClose
        let changeAmount = point.price - previousClose
        let changePercent = previousClose > 0 ? changeAmount / previousClose * 100 : 0
        let color: Color = changeAmount > 0 ? .red : changeAmount < 0 ? .green : .primary

        return VStack(spacing: 1) {
            HStack(spacing: 4) {
                Circle()
                    .fill(.green)
                    .frame(width: 5, height: 5)
                Text("自动刷新 · 每15秒")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(point.time)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Text(point.price.priceString)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color)
                Text(changeAmount >= 0 ? "+\(changeAmount.priceString)" : changeAmount.priceString)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(color)
                Text(changePercent >= 0 ? "+\(String(format: "%.2f", changePercent))%" : "\(String(format: "%.2f", changePercent))%")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(color)
                Spacer()
                Text("\(point.cumulativeVolume)手")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func leftAxis(data: MinuteData) -> some View {
        let percent = symmetricPercent(data: data)

        return VStack(alignment: .trailing, spacing: 0) {
            Text("+\(String(format: "%.1f", percent))%").axisLabel()
            Spacer()
            Text("0%").axisLabel()
            Spacer()
            Text("-\(String(format: "%.1f", percent))%").axisLabel()
        }
        .padding(.vertical, 2)
    }

    private func rightAxis(data: MinuteData) -> some View {
        let prices = data.points.map(\.price)
        let high = prices.max() ?? data.previousClose
        let low = prices.min() ?? data.previousClose

        return VStack(alignment: .leading, spacing: 0) {
            Text(high.priceString).axisLabel()
            Spacer()
            Text(data.previousClose.priceString)
                .font(.system(size: 8).monospacedDigit())
                .foregroundStyle(.gray)
            Spacer()
            Text(low.priceString).axisLabel()
        }
        .padding(.vertical, 2)
    }

    private var timeAxis: some View {
        HStack {
            Text("09:30")
            Spacer()
            Text("11:30")
            Spacer()
            Text("15:00")
        }
        .font(.system(size: 8))
        .foregroundStyle(.secondary)
    }

    private func symmetricPercent(data: MinuteData) -> Double {
        guard data.previousClose > 0 else {
            return 2
        }

        let values = data.points.map(\.price) + [data.previousClose]
        let halfRange = max(
            abs((values.max() ?? data.previousClose) - data.previousClose),
            abs(data.previousClose - (values.min() ?? data.previousClose)),
            data.previousClose * 0.005
        )
        return halfRange / data.previousClose * 100
    }
}

private struct IntradayCanvas: View {
    let data: MinuteData
    let selectedIndex: Int

    var body: some View {
        Canvas { context, size in
            draw(context: context, size: size)
        }
        .clipped()
    }

    private func draw(context: GraphicsContext, size: CGSize) {
        guard !data.points.isEmpty else {
            return
        }

        let points = data.points
        let previousClose = data.previousClose
        let totalSlots = 240
        let values = points.flatMap { [$0.price, $0.avgPrice] } + [previousClose]
        let halfRange = max(
            abs((values.max() ?? previousClose) - previousClose),
            abs(previousClose - (values.min() ?? previousClose)),
            previousClose * 0.005
        )
        let yMax = previousClose + halfRange
        let yMin = previousClose - halfRange

        func xPosition(_ index: Int) -> CGFloat {
            size.width * CGFloat(index) / CGFloat(totalSlots - 1)
        }

        func yPosition(_ price: Double) -> CGFloat {
            guard yMax > yMin else {
                return size.height / 2
            }
            return size.height * CGFloat(1 - (price - yMin) / (yMax - yMin))
        }

        let baselineY = yPosition(previousClose)
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: baselineY))
        baseline.addLine(to: CGPoint(x: size.width, y: baselineY))
        context.stroke(
            baseline,
            with: .color(.gray.opacity(0.4)),
            style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])
        )

        guard points.count >= 2 else {
            return
        }

        var pricePath = Path()
        pricePath.move(to: CGPoint(x: xPosition(points[0].minuteIndex), y: yPosition(points[0].price)))
        for point in points.dropFirst() {
            pricePath.addLine(to: CGPoint(x: xPosition(point.minuteIndex), y: yPosition(point.price)))
        }

        var fillPath = pricePath
        fillPath.addLine(to: CGPoint(x: xPosition(points.last!.minuteIndex), y: size.height))
        fillPath.addLine(to: CGPoint(x: xPosition(points.first!.minuteIndex), y: size.height))
        fillPath.closeSubpath()
        context.fill(fillPath, with: .color(.yellow.opacity(0.10)))
        context.stroke(pricePath, with: .color(.yellow), style: StrokeStyle(lineWidth: 2.0, lineJoin: .round))

        var avgPath = Path()
        avgPath.move(to: CGPoint(x: xPosition(points[0].minuteIndex), y: yPosition(points[0].avgPrice)))
        for point in points.dropFirst() {
            avgPath.addLine(to: CGPoint(x: xPosition(point.minuteIndex), y: yPosition(point.avgPrice)))
        }
        context.stroke(avgPath, with: .color(.orange.opacity(0.85)), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))

        let selected = points[min(selectedIndex, points.count - 1)]
        let selectedX = xPosition(selected.minuteIndex)
        let selectedY = yPosition(selected.price)

        var crosshair = Path()
        crosshair.move(to: CGPoint(x: selectedX, y: 0))
        crosshair.addLine(to: CGPoint(x: selectedX, y: size.height))
        context.stroke(crosshair, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 0.75, dash: [2, 2]))

        let radius: CGFloat = 3.5
        context.fill(
            Path(ellipseIn: CGRect(x: selectedX - radius - 1.5, y: selectedY - radius - 1.5, width: (radius + 1.5) * 2, height: (radius + 1.5) * 2)),
            with: .color(.white.opacity(0.25))
        )
        context.fill(
            Path(ellipseIn: CGRect(x: selectedX - radius, y: selectedY - radius, width: radius * 2, height: radius * 2)),
            with: .color(.yellow)
        )
    }
}

private extension Text {
    func axisLabel() -> some View {
        font(.system(size: 8).monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

private extension Double {
    var priceString: String {
        String(format: "%.2f", self)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
