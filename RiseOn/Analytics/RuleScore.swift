import Foundation

/// Minimal S2.2 holding-structure shape for a stock's rule-based score.
///
/// This is deliberately **not** the full port of
/// `src/stock_analyzer.py::TrendAnalysisResult` yet — the status enums
/// (`TrendStatus`/`VolumeStatus`/`MACDStatus`/`RSIStatus`/`BuySignal`), the
/// weighted scoring breakdown, and `support_levels`/`resistance_levels` are
/// added by the engine in S7.1-S7.4 (`RuleScoreEngine`, plan.md §0.5-1/§0.5-5).
/// S2 only needs `RuleScore` to exist as a concrete, `Codable` type that a
/// `StockWorkspace` can hold.
public struct RuleScore: Codable, Equatable, Hashable, Sendable {
    public var code: String
    public var signalScore: Int
    public var updatedAt: Date

    public init(code: String, signalScore: Int = 0, updatedAt: Date = Date()) {
        self.code = code
        self.signalScore = signalScore
        self.updatedAt = updatedAt
    }
}
