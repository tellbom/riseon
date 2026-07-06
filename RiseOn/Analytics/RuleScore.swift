import Foundation

/// Full Swift port of `src/stock_analyzer.py::TrendAnalysisResult` (task.md
/// S7.2), computed by `RuleScoreEngine.analyze(bars:code:)`.
///
/// Field-for-field mirror of the Python dataclass, including its defaults —
/// a freshly-constructed `RuleScore(code:)` (nothing else supplied) matches
/// what `analyze()` returns for the "数据不足" (insufficient data) early-out
/// case, same as `TrendAnalysisResult(code=code)` does on the Python side.
public struct RuleScore: Codable, Equatable, Hashable, Sendable {
    public var code: String
    public var updatedAt: Date

    // 趋势判断
    public var trendStatus: TrendStatus
    public var maAlignment: String
    public var trendStrength: Double

    // 均线数据
    public var ma5: Double
    public var ma10: Double
    public var ma20: Double
    public var ma60: Double
    public var currentPrice: Double

    // 乖离率
    public var biasMA5: Double
    public var biasMA10: Double
    public var biasMA20: Double

    // 量能分析
    public var volumeStatus: VolumeStatus
    public var volumeRatio5d: Double
    public var volumeTrend: String

    // 支撑压力（levels，供 ContextPack `levels` 块 / stop_loss 回退使用，见 §0.5-1/§0.5-5）
    public var supportMA5: Bool
    public var supportMA10: Bool
    public var resistanceLevels: [Double]
    public var supportLevels: [Double]

    // MACD 指标
    public var macdDIF: Double
    public var macdDEA: Double
    public var macdBar: Double
    public var macdStatus: MACDStatus
    public var macdSignal: String

    // RSI 指标
    public var rsi6: Double
    public var rsi12: Double
    public var rsi24: Double
    public var rsiStatus: RSIStatus
    public var rsiSignal: String

    // 买入信号
    public var buySignal: BuySignal
    public var signalScore: Int
    public var signalReasons: [String]
    public var riskFactors: [String]

    public init(
        code: String,
        updatedAt: Date = Date(),
        trendStatus: TrendStatus = .consolidation,
        maAlignment: String = "",
        trendStrength: Double = 0,
        ma5: Double = 0,
        ma10: Double = 0,
        ma20: Double = 0,
        ma60: Double = 0,
        currentPrice: Double = 0,
        biasMA5: Double = 0,
        biasMA10: Double = 0,
        biasMA20: Double = 0,
        volumeStatus: VolumeStatus = .normal,
        volumeRatio5d: Double = 0,
        volumeTrend: String = "",
        supportMA5: Bool = false,
        supportMA10: Bool = false,
        resistanceLevels: [Double] = [],
        supportLevels: [Double] = [],
        macdDIF: Double = 0,
        macdDEA: Double = 0,
        macdBar: Double = 0,
        macdStatus: MACDStatus = .bullish,
        macdSignal: String = "",
        rsi6: Double = 0,
        rsi12: Double = 0,
        rsi24: Double = 0,
        rsiStatus: RSIStatus = .neutral,
        rsiSignal: String = "",
        buySignal: BuySignal = .wait,
        signalScore: Int = 0,
        signalReasons: [String] = [],
        riskFactors: [String] = []
    ) {
        self.code = code
        self.updatedAt = updatedAt
        self.trendStatus = trendStatus
        self.maAlignment = maAlignment
        self.trendStrength = trendStrength
        self.ma5 = ma5
        self.ma10 = ma10
        self.ma20 = ma20
        self.ma60 = ma60
        self.currentPrice = currentPrice
        self.biasMA5 = biasMA5
        self.biasMA10 = biasMA10
        self.biasMA20 = biasMA20
        self.volumeStatus = volumeStatus
        self.volumeRatio5d = volumeRatio5d
        self.volumeTrend = volumeTrend
        self.supportMA5 = supportMA5
        self.supportMA10 = supportMA10
        self.resistanceLevels = resistanceLevels
        self.supportLevels = supportLevels
        self.macdDIF = macdDIF
        self.macdDEA = macdDEA
        self.macdBar = macdBar
        self.macdStatus = macdStatus
        self.macdSignal = macdSignal
        self.rsi6 = rsi6
        self.rsi12 = rsi12
        self.rsi24 = rsi24
        self.rsiStatus = rsiStatus
        self.rsiSignal = rsiSignal
        self.buySignal = buySignal
        self.signalScore = signalScore
        self.signalReasons = signalReasons
        self.riskFactors = riskFactors
    }
}
