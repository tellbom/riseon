import Foundation

public struct WatchlistItem: Hashable, Codable, Identifiable, Sendable {
    public nonisolated var id: String { code }

    public let code: String
    public var name: String

    public nonisolated init(code: String, name: String = "") {
        self.code = code
        self.name = name
    }
}
