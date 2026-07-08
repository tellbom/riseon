import Foundation

/// The actual "ask this stock a question" flow (task.md S16.5) —
/// `PromptBuilder` (S9), `LLMService` (S10), and `ChatThread` isolation
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
    /// and the answer to the workspace's active `ChatThread` (via
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
        llmService: any LLMService,
        options: PromptBuilder.Options = PromptBuilder.Options()
    ) async throws -> String {
        guard let pack = workspace.contextPack else {
            throw ChatServiceError.workspaceNotReady
        }

        let prompt = PromptBuilder.build(
            pack: pack,
            ruleScore: workspace.ruleScore,
            history: workspace.activeChatThread?.messages ?? [],
            question: question,
            options: options
        )

        try workspace.appendChatMessage(ChatMessage(role: .user, content: question))

        let answer = try await llmService.generate(system: prompt.system, user: prompt.user)

        try workspace.appendChatMessage(ChatMessage(role: .assistant, content: answer))
        return answer
    }

    /// Streaming counterpart to `ask`: records the user's question
    /// immediately (same "don't lose the question" guarantee as `ask`),
    /// then returns the raw token stream from `llmService.streamGenerate`
    /// unmodified — accumulating the delta text into a displayable/storable
    /// answer is the caller's job (the chat UI needs the partial text to
    /// render as it arrives, so accumulation can't happen down here).
    ///
    /// Call `finalizeStreamedAnswer` once the stream completes successfully
    /// to record the assistant's side of the exchange; if the stream throws,
    /// don't call it, mirroring `ask`'s "no assistant message on failure".
    public static func streamAsk(
        _ question: String,
        in workspace: inout StockWorkspace,
        llmService: any LLMService,
        options: PromptBuilder.Options = PromptBuilder.Options()
    ) throws -> AsyncThrowingStream<String, Error> {
        guard let pack = workspace.contextPack else {
            throw ChatServiceError.workspaceNotReady
        }

        let prompt = PromptBuilder.build(
            pack: pack,
            ruleScore: workspace.ruleScore,
            history: workspace.activeChatThread?.messages ?? [],
            question: question,
            options: options
        )

        try workspace.appendChatMessage(ChatMessage(role: .user, content: question))

        return llmService.streamGenerate(system: prompt.system, user: prompt.user)
    }

    /// Records the assistant's fully-accumulated answer after a
    /// `streamAsk` stream finished without error.
    public static func finalizeStreamedAnswer(_ content: String, in workspace: inout StockWorkspace) throws {
        try workspace.appendChatMessage(ChatMessage(role: .assistant, content: content))
    }

    /// Same contract as `streamAsk`, but via `llmService.streamGenerateEvents`
    /// so the caller also sees `.searching`/`.searchDone` "thinking" events
    /// from the `web_search` tool round, not just the final answer's token
    /// stream. Callers accumulate `.answerDelta` chunks themselves (same as
    /// `streamAsk`) and still call `finalizeStreamedAnswer` once the stream
    /// completes successfully.
    public static func streamAskEvents(
        _ question: String,
        in workspace: inout StockWorkspace,
        llmService: any LLMService,
        options: PromptBuilder.Options = PromptBuilder.Options()
    ) throws -> AsyncThrowingStream<LLMStreamEvent, Error> {
        guard let pack = workspace.contextPack else {
            throw ChatServiceError.workspaceNotReady
        }

        let prompt = PromptBuilder.build(
            pack: pack,
            ruleScore: workspace.ruleScore,
            history: workspace.activeChatThread?.messages ?? [],
            question: question,
            options: options
        )

        try workspace.appendChatMessage(ChatMessage(role: .user, content: question))

        return llmService.streamGenerateEvents(system: prompt.system, user: prompt.user)
    }
}
