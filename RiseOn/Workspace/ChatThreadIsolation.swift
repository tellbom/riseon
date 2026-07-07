import Foundation

/// Enforces task.md S11.1's hard constraint: every `ChatThread` in a
/// workspace's `chatThreads` must only ever belong to the `StockWorkspace`
/// whose `code` it matches — "A 股会话不出现在 B 股上下文". Under normal use
/// this can't actually drift (`StockWorkspace.init`/`startNewChatThread`
/// always stamp the workspace's own `code`), but these are the sanctioned
/// mutation points that check anyway, so a future bug that swaps threads
/// between workspaces fails loudly with a specific, testable error instead
/// of silently leaking one stock's chat history into another's LLM prompt.
extension StockWorkspace {
    public enum ChatIsolationError: Error, Equatable, Sendable {
        case codeMismatch(sessionCode: String, workspaceCode: String)
    }

    public enum ChatThreadError: Error, Equatable, Sendable {
        case threadNotFound(UUID)
        case noActiveThread
    }

    /// The sanctioned way to grow the *active* thread's history. Appending
    /// directly via `workspace.chatThreads[i].messages.append(...)` still
    /// works (this doesn't lock the property down) but skips this check —
    /// prefer this method at any real call site.
    @discardableResult
    public mutating func appendChatMessage(_ message: ChatMessage) throws -> ChatThread {
        try assertChatSessionIsolated()
        guard let activeChatThreadID, let index = chatThreads.firstIndex(where: { $0.id == activeChatThreadID }) else {
            throw ChatThreadError.noActiveThread
        }
        chatThreads[index].messages.append(message)
        chatThreads[index].updatedAt = message.createdAt
        return chatThreads[index]
    }

    /// Starts a brand-new, empty thread for this workspace's stock, makes it
    /// the active one, and returns it — the entry point for the "新建会话"
    /// action in the chat UI.
    @discardableResult
    public mutating func startNewChatThread() -> ChatThread {
        let thread = ChatThread(code: code)
        chatThreads.append(thread)
        activeChatThreadID = thread.id
        return thread
    }

    /// Switches the active thread to `id` — the entry point for tapping a
    /// row in `ChatThreadListView`. Throws rather than silently no-op'ing if
    /// `id` doesn't belong to this workspace.
    public mutating func selectChatThread(id: UUID) throws {
        guard chatThreads.contains(where: { $0.id == id }) else {
            throw ChatThreadError.threadNotFound(id)
        }
        activeChatThreadID = id
    }

    /// Removes the thread `id`. If it was the last remaining thread (or the
    /// active one), a fresh empty thread is created and made active so
    /// `activeChatThread` is never left `nil` — mirrors why `init` always
    /// seeds one thread up front.
    public mutating func deleteChatThread(id: UUID) throws {
        guard chatThreads.contains(where: { $0.id == id }) else {
            throw ChatThreadError.threadNotFound(id)
        }
        chatThreads.removeAll { $0.id == id }
        if chatThreads.isEmpty {
            let replacement = ChatThread(code: code)
            chatThreads = [replacement]
            activeChatThreadID = replacement.id
        } else if activeChatThreadID == id {
            activeChatThreadID = chatThreads.last?.id
        }
    }

    /// Standalone check, for callers that just want to verify the invariant
    /// still holds (e.g. right after loading from disk) without mutating
    /// anything. Checks *every* thread, not just the active one.
    public func assertChatSessionIsolated() throws {
        for thread in chatThreads where thread.code != code {
            throw ChatIsolationError.codeMismatch(sessionCode: thread.code, workspaceCode: code)
        }
    }
}
