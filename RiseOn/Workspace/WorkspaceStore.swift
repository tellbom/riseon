import Foundation

/// Per-stock isolated persistence for `StockWorkspace` (task.md S3.1, plan.md §5/§7).
///
/// Each stock is stored as its own file (`{code}.json`) under a dedicated
/// directory (defaults to `Application Support/Workspaces/`), so one stock's
/// read/write/corruption never touches another's — this is the "隔离"
/// (isolation) the task asks for, done via the filesystem rather than a
/// single shared blob (contrast with `WatchlistStore`, which intentionally
/// stores one combined list since watchlist items aren't isolated data).
///
/// Writes are atomic (`Data.write(options: .atomic)`: written to a temp file
/// next to the destination, then swapped in, so a crash mid-write can't leave
/// a half-written/corrupt file).
///
/// An `actor` rather than a `@MainActor` `ObservableObject` (unlike
/// `WatchlistStore`) because this will be read/written both from UI code and
/// from the background `InitializationQueue` (S4) — actor isolation makes
/// that safe without extra locking. A thin `@MainActor` view-model wrapper
/// can be added later (S13) if SwiftUI needs to observe it reactively.
public actor WorkspaceStore {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter directory: where per-stock JSON files are written. Pass an
    ///   explicit value in tests (e.g. a temp directory); defaults to
    ///   `Application Support/Workspaces/` for real app use.
    public init(directory: URL? = nil) throws {
        let resolvedDirectory = try directory ?? Self.defaultDirectory()
        self.directory = resolvedDirectory

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        try FileManager.default.createDirectory(at: resolvedDirectory, withIntermediateDirectories: true)
    }

    // MARK: - CRUD

    /// Writes `workspace` to its own file, creating or overwriting as needed.
    public func save(_ workspace: StockWorkspace) async throws {
        let data = try encoder.encode(workspace)
        try data.write(to: fileURL(for: workspace.code), options: .atomic)
    }

    /// Reads the workspace for `code`, or `nil` if none has been saved.
    ///
    /// A file that exists but fails to decode (e.g. it predates a
    /// `StockWorkspace` schema change) is treated the same as "never
    /// saved" rather than thrown: it's deleted and `nil` is returned, so
    /// callers naturally fall back to their existing "no workspace yet"
    /// path (`WorkspaceInitializationCoordinator.startInitialization`
    /// rebuilds and overwrites it) instead of surfacing a raw decode error
    /// for every stock whenever the on-disk shape moves on. Mirrors the
    /// same per-file tolerance `loadAll()` already has.
    public func load(code: String) async throws -> StockWorkspace? {
        let url = fileURL(for: code)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        do {
            return try decoder.decode(StockWorkspace.self, from: data)
        } catch is DecodingError {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Removes the file for `code`. Idempotent — does not throw if nothing
    /// was stored for that code.
    public func delete(code: String) async throws {
        let url = fileURL(for: code)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }

    /// All codes currently persisted, sorted for stable ordering.
    public func allCodes() async throws -> [String] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return files
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Convenience for loading every persisted workspace at once (e.g. to
    /// populate the Home list, S13+). Skips any file that fails to decode
    /// rather than failing the whole batch — a single corrupt workspace
    /// file shouldn't take down the others (same isolation principle as
    /// storing them separately in the first place).
    public func loadAll() async throws -> [StockWorkspace] {
        var results: [StockWorkspace] = []
        for code in try await allCodes() {
            if let workspace = try? await load(code: code) {
                results.append(workspace)
            }
        }
        return results
    }

    // MARK: - Paths

    private func fileURL(for code: String) -> URL {
        directory.appendingPathComponent("\(Self.sanitizedFileName(for: code)).json")
    }

    /// Defends against path traversal / invalid filename characters. Stock
    /// codes are always validated 6-digit strings by the time they reach
    /// here (`ACodeResolver`), so this is a defensive backstop, not the
    /// primary validation.
    private static func sanitizedFileName(for code: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return String(code.unicodeScalars.filter { allowed.contains($0) })
    }

    private static func defaultDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent("Workspaces", isDirectory: true)
    }
}
