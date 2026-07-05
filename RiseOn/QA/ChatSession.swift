import Foundation

/// Minimal S2.2 holding-structure shape for a stock's isolated chat history.
///
/// `code` is the isolation key: a `ChatSession` must only ever be read/written
/// through the `StockWorkspace` whose `code` matches (task.md S11.1's hard
/// constraint — enforced in S11, not here). Token-budget truncation and the
/// 5-section summary-compression placeholder (`chat_context` idea) are added
/// in S11.2. S2 only needs `ChatSession` to exist as a concrete, `Codable`
/// type that a `StockWorkspace` can hold.
public struct ChatSession: Codable, Equatable, Hashable, Sendable {
    public var code: String
    public var messages: [ChatMessage]

    public init(code: String, messages: [ChatMessage] = []) {
        self.code = code
        self.messages = messages
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
