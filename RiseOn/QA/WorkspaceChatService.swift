import Foundation

/// The actual "ask this stock a question" flow (task.md S16.5) —
/// `PromptBuilder` (S9), `LLMService` (S10), and `ChatSession` isolation
/// (S11) all exist as separate pieces already; this is what calls them
/// together in the right order and records both sides of the exchange.
public enum WorkspaceChatService {

    public enum ChatServiceError: Error, Equatable, Sendable {
        /// No `ContextPack` yet — the workspace hasn't finished
        /// initializing (or initialization failed before ever producing
        /// one). Ask again once it's `.ready`/`.partial`/`.stale`.
        case workspaceNotReady
    }

    /// Sends `question` through this workspace's own `ContextPack`/history,
    /// gets an answer from `llmService`, and appends **both** the question
    /// and the answer to `workspace.chatSession` (via
    /// `StockWorkspace.appendChatMessage`, so S11.1's isolation check still
    /// applies here too — this doesn't bypass it).
    ///
    /// If `llmService.generate` throws, the user's question is still
    /// recorded (so it isn't silently lost — the person can see what they
    /// asked and retry), but no assistant message is appended, and the
    /// error propagates for the caller to show a clear error state
    /// (task.md S10.2's own requirement).
    @discardableResult
    public static func ask(
        _ question: String,
        in workspace: inout StockWorkspace,
        llmService: any LLMService
    ) async throws -> String {
        guard let pack = workspace.contextPack else {
            throw ChatServiceError.workspaceNotReady
        }

        let prompt = PromptBuilder.build(
            pack: pack,
            ruleScore: workspace.ruleScore,
            history: workspace.chatSession.messages,
            question: question
        )

        try workspace.appendChatMessage(ChatMessage(role: .user, content: question))

        let answer = try await llmService.generate(system: prompt.system, user: prompt.user)

        try workspace.appendChatMessage(ChatMessage(role: .assistant, content: answer))
        return answer
    }
}
