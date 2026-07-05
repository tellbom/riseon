import Foundation

/// Snapshot bookkeeping for a `StockWorkspace` (task.md S2.2): when the data
/// was last fetched, where it came from, and a coarse quality label.
///
/// `quality` mirrors `ContextPack.dataQuality.level` once S8.3 exists
/// (good/usable/limited/poor) but is kept as a plain `String?` here so S2
/// doesn't have to depend on S8's not-yet-built quality enum.
public struct WorkspaceMeta: Codable, Equatable, Hashable, Sendable {
    public var snapshotDate: Date?
    public var source: String
    public var quality: String?

    public init(snapshotDate: Date?, source: String, quality: String?) {
        self.snapshotDate = snapshotDate
        self.source = source
        self.quality = quality
    }
}
