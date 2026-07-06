import Foundation

/// Full Swift port of `src/schemas/analysis_context_pack.py` (task.md S8.1).
///
/// Deliberately **not** ported: `AnalysisContextPack.phase` (server pipeline
/// execution-phase bookkeeping — nothing in this on-device app ever
/// populates it), and `to_safe_dict()`/`model_copy()` (Pydantic model
/// helpers; `to_safe_dict()` specifically redacts sensitive values for a
/// **multi-tenant server** context, which doesn't apply here — this pack
/// never leaves the person's own device except into their own LLM prompt).
/// Everything else mirrors the Python schema field-for-field, including
/// JSON key names (see each type's `CodingKeys`) — task.md S8.1's
/// verification point is that serialized field names and status values
/// match the Python side exactly.

/// Mirrors `ContextFieldStatus(str, Enum)` — note this is a `str` enum on
/// the Python side, so raw values (not case names) are what serializes.
public enum ContextFieldStatus: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case available
    case missing
    case notSupported = "not_supported"
    case fallback
    case stale
    case estimated
    case partial
    case fetchFailed = "fetch_failed"
}

/// Mirrors `AnalysisSubject`.
public struct ContextPackSubject: Codable, Equatable, Hashable, Sendable {
    public var code: String
    public var stockName: String?
    public var market: String?

    private enum CodingKeys: String, CodingKey {
        case code
        case stockName = "stock_name"
        case market
    }

    public init(code: String, stockName: String? = nil, market: String? = nil) {
        self.code = code
        self.stockName = stockName
        self.market = market
    }
}

/// Mirrors `AnalysisContextItem` — one field-level input inside a block.
public struct ContextItem: Codable, Equatable, Hashable, Sendable {
    public var status: ContextFieldStatus
    public var value: JSONValue?
    public var source: String?
    public var timestamp: String?
    public var fallbackFrom: String?
    public var missingReason: String?
    public var warnings: [String]
    public var metadata: [String: JSONValue]

    private enum CodingKeys: String, CodingKey {
        case status, value, source, timestamp
        case fallbackFrom = "fallback_from"
        case missingReason = "missing_reason"
        case warnings, metadata
    }

    public init(
        status: ContextFieldStatus,
        value: JSONValue? = nil,
        source: String? = nil,
        timestamp: String? = nil,
        fallbackFrom: String? = nil,
        missingReason: String? = nil,
        warnings: [String] = [],
        metadata: [String: JSONValue] = [:]
    ) {
        self.status = status
        self.value = value
        self.source = source
        self.timestamp = timestamp
        self.fallbackFrom = fallbackFrom
        self.missingReason = missingReason
        self.warnings = warnings
        self.metadata = metadata
    }
}

/// Mirrors `AnalysisContextBlock` — a named group of related `ContextItem`s
/// (e.g. `quote`, `technical`), plus its own overall status/warnings.
public struct ContextBlock: Codable, Equatable, Hashable, Sendable {
    public var status: ContextFieldStatus
    public var items: [String: ContextItem]
    public var source: String?
    public var timestamp: String?
    public var warnings: [String]
    public var metadata: [String: JSONValue]

    public init(
        status: ContextFieldStatus,
        items: [String: ContextItem] = [:],
        source: String? = nil,
        timestamp: String? = nil,
        warnings: [String] = [],
        metadata: [String: JSONValue] = [:]
    ) {
        self.status = status
        self.items = items
        self.source = source
        self.timestamp = timestamp
        self.warnings = warnings
        self.metadata = metadata
    }
}

/// Mirrors `DataQuality`.
public struct DataQuality: Codable, Equatable, Hashable, Sendable {
    public var overallScore: Int?
    /// `"good" | "usable" | "limited" | "poor"` — kept as a plain `String?`
    /// rather than a Swift enum since `ContextPackBuilder` (S8.3) is the
    /// only writer and always uses one of those four literals; adding a
    /// dedicated enum here wouldn't buy type safety Swift doesn't already
    /// get from that single call site.
    public var level: String?
    public var blockScores: [String: Int]
    public var limitations: [String]
    public var warnings: [String]
    public var metadata: [String: JSONValue]

    private enum CodingKeys: String, CodingKey {
        case overallScore = "overall_score"
        case level
        case blockScores = "block_scores"
        case limitations, warnings, metadata
    }

    public init(
        overallScore: Int? = nil,
        level: String? = nil,
        blockScores: [String: Int] = [:],
        limitations: [String] = [],
        warnings: [String] = [],
        metadata: [String: JSONValue] = [:]
    ) {
        self.overallScore = overallScore
        self.level = level
        self.blockScores = blockScores
        self.limitations = limitations
        self.warnings = warnings
        self.metadata = metadata
    }
}

/// Mirrors `AnalysisContextPack` (minus `phase`, see file-level doc comment).
public struct ContextPack: Codable, Equatable, Hashable, Sendable {
    public var subject: ContextPackSubject
    public var packVersion: String
    public var blocks: [String: ContextBlock]
    public var dataQuality: DataQuality
    public var metadata: [String: JSONValue]
    public var createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case subject
        case packVersion = "pack_version"
        case blocks
        case dataQuality = "data_quality"
        case metadata
        case createdAt = "created_at"
    }

    public init(
        subject: ContextPackSubject,
        packVersion: String = "1.0",
        blocks: [String: ContextBlock] = [:],
        dataQuality: DataQuality = DataQuality(),
        metadata: [String: JSONValue] = [:],
        createdAt: Date = Date()
    ) {
        self.subject = subject
        self.packVersion = packVersion
        self.blocks = blocks
        self.dataQuality = dataQuality
        self.metadata = metadata
        self.createdAt = createdAt
    }
}
