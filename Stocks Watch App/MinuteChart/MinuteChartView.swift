import SwiftUI

struct MinuteChartView: View {
    @StateObject private var viewModel: MinuteChartViewModel

    init(symbol: StockSymbol, previousClose: Double) {
        _viewModel = StateObject(
            wrappedValue: MinuteChartViewModel(symbol: symbol, previousClose: previousClose)
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
                VStack(spacing: 6) {
                    ProgressView()
                    Text("加载分时线...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .loaded(let data):
                chartContent(data)
            case .error(let message):
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
        }
        .navigationTitle("分时线")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func chartContent(_ data: MinuteData) -> some View {
        VStack(spacing: 4) {
            priceRangeHeader(data)
            MinuteLineChart(data: data)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            timeAxisFooter
        }
        .padding(.horizontal, 2)
    }

    private func priceRangeHeader(_ data: MinuteData) -> some View {
        let prices = data.points.map(\.price)
        let maxPrice = prices.max() ?? data.previousClose
        let minPrice = prices.min() ?? data.previousClose

        return HStack {
            Text(minPrice.priceFormatted)
            Spacer()
            Text("均 \((data.points.last?.avgPrice ?? data.previousClose).priceFormatted)")
                .foregroundStyle(.orange)
            Spacer()
            Text(maxPrice.priceFormatted)
        }
        .font(.system(size: 9).monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var timeAxisFooter: some View {
        HStack {
            Text("09:30")
            Spacer()
            Text("11:30")
            Spacer()
            Text("13:00")
            Spacer()
            Text("15:00")
        }
        .font(.system(size: 8))
        .foregroundStyle(.secondary)
    }
}

private struct MinuteLineChart: View {
    let data: MinuteData

    var body: some View {
        Canvas { context, size in
            guard data.points.count >= 2 else {
                return
            }

            let totalSlots = 240
            let previousClose = data.previousClose
            let allValues = data.points.flatMap { [$0.price, $0.avgPrice] } + [previousClose]
            let rawMax = allValues.max() ?? previousClose
            let rawMin = allValues.min() ?? previousClose
            let halfRange = max(abs(rawMax - previousClose), abs(previousClose - rawMin), previousClose * 0.005)
            let yMax = previousClose + halfRange
            let yMin = previousClose - halfRange

            func xPosition(_ index: Int) -> CGFloat {
                size.width * CGFloat(index) / CGFloat(totalSlots - 1)
            }

            func yPosition(_ price: Double) -> CGFloat {
                let ratio = (price - yMin) / (yMax - yMin)
                return size.height * (1 - CGFloat(ratio))
            }

            var baseline = Path()
            let baselineY = yPosition(previousClose)
            baseline.move(to: CGPoint(x: 0, y: baselineY))
            baseline.addLine(to: CGPoint(x: size.width, y: baselineY))
            context.stroke(
                baseline,
                with: .color(.gray.opacity(0.4)),
                style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])
            )

            var pricePath = Path()
            pricePath.move(
                to: CGPoint(x: xPosition(data.points[0].minuteIndex), y: yPosition(data.points[0].price))
            )
            for point in data.points.dropFirst() {
                pricePath.addLine(to: CGPoint(x: xPosition(point.minuteIndex), y: yPosition(point.price)))
            }

            let lineColor: Color = (data.points.last?.price ?? previousClose) >= previousClose ? .red : .green
            context.stroke(pricePath, with: .color(lineColor), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))

            var fillPath = pricePath
            fillPath.addLine(to: CGPoint(x: xPosition(data.points.last!.minuteIndex), y: size.height))
            fillPath.addLine(to: CGPoint(x: xPosition(data.points.first!.minuteIndex), y: size.height))
            fillPath.closeSubpath()
            context.fill(fillPath, with: .color(lineColor.opacity(0.12)))

            var avgPath = Path()
            avgPath.move(
                to: CGPoint(x: xPosition(data.points[0].minuteIndex), y: yPosition(data.points[0].avgPrice))
            )
            for point in data.points.dropFirst() {
                avgPath.addLine(to: CGPoint(x: xPosition(point.minuteIndex), y: yPosition(point.avgPrice)))
            }
            context.stroke(avgPath, with: .color(.orange.opacity(0.85)), style: StrokeStyle(lineWidth: 1))
        }
    }
}

private extension Double {
    var priceFormatted: String {
        String(format: "%.2f", self)
    }
}
