import Foundation

/// Enforces task.md S11.1's hard constraint: a `ChatSession` must only ever
/// be read/written through the `StockWorkspace` whose `code` it matches —
/// "A 股会话不出现在 B 股上下文". Under normal use this can't actually
/// drift (`StockWorkspace.init` always creates `chatSession` with the same
/// `code`), but these are the sanctioned mutation points that check anyway,
/// so a future bug that swaps sessions between workspaces fails loudly with
/// a specific, testable error instead of silently leaking one stock's chat
/// history into another's LLM prompt.
extension StockWorkspace {
    public enum ChatIsolationError: Error, Equatable, Sendable {
        case codeMismatch(sessionCode: String, workspaceCode: String)
    }

    /// The sanctioned way to grow this workspace's own chat history.
    /// Appending directly via `workspace.chatSession.messages.append(...)`
    /// still works (this doesn't lock the property down) but skips this
    /// check — prefer this method at any real call site.
    @discardableResult
    public mutating func appendChatMessage(_ message: ChatMessage) throws -> ChatSession {
        try assertChatSessionIsolated()
        chatSession.messages.append(message)
        return chatSession
    }

    /// Swaps in a whole new `ChatSession` (e.g. after loading a workspace
    /// from `WorkspaceStore`, or restoring one from a backup) — rejected
    /// outright if its `code` doesn't match this workspace's `code`, rather
    /// than silently adopting a different stock's history.
    public mutating func replaceChatSession(with newSession: ChatSession) throws {
        guard newSession.code == code else {
            throw ChatIsolationError.codeMismatch(sessionCode: newSession.code, workspaceCode: code)
        }
        chatSession = newSession
    }

    /// Standalone check, for callers that just want to verify the
    /// invariant still holds (e.g. right after loading from disk) without
    /// mutating anything.
    public func assertChatSessionIsolated() throws {
        guard chatSession.code == code else {
            throw ChatIsolationError.codeMismatch(sessionCode: chatSession.code, workspaceCode: code)
        }
    }
}
