import Foundation

/// Minimal S2.2 holding-structure shape for the per-stock context pack.
///
/// This is deliberately **not** the full port of
/// `src/schemas/analysis_context_pack.py` yet — `blocks` (quote/daily_bars/
/// technical/factors/levels/chip/fundamentals/news/capital_flow/events),
/// `ContextFieldStatus`, and `data_quality` are added in S8.1-S8.3 (plan.md
/// §7). S2 only needs `ContextPack` to exist as a concrete, `Codable` type
/// that a `StockWorkspace` can hold — going further here would get ahead of
/// S8's task.
public struct ContextPack: Codable, Equatable, Hashable, Sendable {
    public var subject: ContextPackSubject
    public var packVersion: String
    public var createdAt: Date

    public init(subject: ContextPackSubject, packVersion: String = "1.0", createdAt: Date = Date()) {
        self.subject = subject
        self.packVersion = packVersion
        self.createdAt = createdAt
    }
}

/// Mirrors `src/schemas/analysis_context_pack.py::AnalysisSubject`.
public struct ContextPackSubject: Codable, Equatable, Hashable, Sendable {
    public var code: String
    public var name: String?
    public var market: String?

    public init(code: String, name: String?, market: String?) {
        self.code = code
        self.name = name
        self.market = market
    }
}
