import Foundation

/// Minimal JSON-file persistence for `InitializationQueue`'s task state
/// (task.md S4.2). Kept separate from `WorkspaceStore`: it's a different
/// kind of data — transient queue bookkeeping (which step each stock is on,
/// retry counts), not a stock's actual content — and the whole thing is one
/// small file rather than one-file-per-stock (there's nothing to isolate
/// between stocks here; losing/corrupting the queue state just means
/// `InitializationQueue` falls back to treating everything as not-yet-run,
/// which is safe since every step is idempotent per plan.md §6).
///
/// A plain (non-actor) `Sendable` struct: each call is a self-contained file
/// read/write with no shared mutable state to protect, so there's nothing an
/// actor would add here. `InitializationQueue` (which does have shared
/// mutable state) is the actor; this is just its persistence backend.
public struct InitQueueStore: Sendable {
    private let fileURL: URL

    /// - Parameter directory: where the queue-state file is written. Pass an
    ///   explicit value in tests (e.g. a temp directory); defaults to
    ///   `Application Support/InitQueue/` for real app use.
    public init(directory: URL? = nil) throws {
        let resolvedDirectory = try directory ?? Self.defaultDirectory()
        try FileManager.default.createDirectory(at: resolvedDirectory, withIntermediateDirectories: true)
        self.fileURL = resolvedDirectory.appendingPathComponent("init_queue_state.json")
    }

    /// Overwrites the persisted state with `tasksByCode`. Atomic, like
    /// `WorkspaceStore.save`.
    public func save(_ tasksByCode: [String: [InitTask]]) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(tasksByCode)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Returns the persisted state, or an empty dictionary if nothing has
    /// been saved yet.
    public func load() async throws -> [String: [InitTask]] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([String: [InitTask]].self, from: data)
    }

    private static func defaultDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent("InitQueue", isDirectory: true)
    }
}
