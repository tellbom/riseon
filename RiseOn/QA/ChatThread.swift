import Foundation

/// One isolated conversation thread for a stock's `StockWorkspace`. A
/// workspace can hold several of these (task.md S11.1's isolation constraint
/// is per-workspace, not per-thread: any thread's `code` must match its
/// owning workspace's `code`, enforced in `ChatThreadIsolation.swift`).
///
/// `title` is optional and never derived/persisted automatically — the UI
/// layer (`ChatThreadListView`) falls back to summarizing the first user
/// message when it's `nil`, so this type doesn't need to know anything about
/// display formatting.
public struct ChatThread: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var code: String
    public var title: String?
    public var messages: [ChatMessage]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        code: String,
        title: String? = nil,
        messages: [ChatMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.code = code
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ChatMessage: Codable, Equatable, Hashable, Sendable {
    public var role: ChatRole
    public var content: String
    public var createdAt: Date

    public init(role: ChatRole, content: String, createdAt: Date = Date()) {
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

public enum ChatRole: String, Codable, Equatable, Hashable, Sendable {
    case user
    case assistant
}
