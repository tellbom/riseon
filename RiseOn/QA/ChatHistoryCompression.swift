import Foundation

/// Keeps a `ChatSession`'s history from growing past what the model's
/// context window can hold (task.md S11.2). MVP strategy: truncate to the
/// most recent messages that fit a token budget. Real summary compression
/// (`ChatHistorySummarizer` below) is reserved for later — this is what
/// ships now.
public enum ChatHistoryCompression {

    /// Rough token estimate. `chat_context.py`'s own token estimator falls
    /// back to `len(text) / 3` whenever a real tokenizer isn't available
    /// (which is always true here — there's no on-device tokenizer for
    /// whatever cloud model `LLMService` ends up pointed at); this mirrors
    /// that exact fallback rather than inventing a different heuristic.
    public static func estimatedTokenCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return Int((Double(text.count) / 3.0).rounded(.up))
    }

    /// Returns the suffix of `messages` (most recent first, in the sense
    /// that recency wins) that fits within `tokenBudget`, preserving
    /// chronological order. Drops the *oldest* messages first — recent
    /// context is almost always more relevant to the current question than
    /// older turns.
    ///
    /// - Parameter tokenBudget: no built-in default on purpose — this
    ///   depends on whichever model `LLMService` is actually configured to
    ///   call (S10's `OpenAICompatibleLLMService.Configuration.model`),
    ///   which this type has no way to know. Callers size it from their own
    ///   model's context window (leaving headroom for the system prompt,
    ///   `ContextPack` rendering, and the question itself).
    public static func truncate(_ messages: [ChatMessage], toFit tokenBudget: Int) -> [ChatMessage] {
        guard tokenBudget > 0, !messages.isEmpty else { return [] }

        var kept: [ChatMessage] = []
        var usedTokens = 0
        for message in messages.reversed() {
            let messageTokens = estimatedTokenCount(message.content)
            guard usedTokens + messageTokens <= tokenBudget else { break }
            kept.append(message)
            usedTokens += messageTokens
        }
        return kept.reversed()
    }
}

/// The 5 required section headers for summary compression, transcribed
/// verbatim from `src/agent/chat_context.py::SUMMARY_SYSTEM_PROMPT`.
public enum ChatSummarySection: String, CaseIterable, Equatable, Sendable {
    case summary = "## 会话摘要"
    case subject = "## 当前关注标的"
    case preferences = "## 用户偏好与约束"
    case judgments = "## 已有判断与操作条件"
    case risks = "## 风险、数据时效与未决问题"
}

/// Placeholder interface for future LLM-backed summary compression
/// (task.md S11.2's "预留 5 段式摘要压缩接口"). Not implemented yet — MVP
/// uses `ChatHistoryCompression.truncate` instead. Exists so there's a real,
/// compilable shape to plug an actual implementation into later without
/// having to redesign `ChatSession`'s call sites when that day comes.
public protocol ChatHistorySummarizer: Sendable {
    /// Compresses `messages` (optionally folding in a `previousSummary`
    /// from an earlier compression pass) into Markdown containing all 5
    /// `ChatSummarySection` headers, in order. Throws on failure (e.g. a
    /// future implementation's underlying `LLMService` call fails) —
    /// callers should fall back to `ChatHistoryCompression.truncate` rather
    /// than surface the error to the user.
    func summarize(messages: [ChatMessage], previousSummary: String?) async throws -> String
}

public enum ChatHistorySummarizerError: Error, Equatable, Sendable {
    case notImplemented
}

/// The MVP's actual `ChatHistorySummarizer` conformer: always fails. Not a
/// bug — task.md S11.2 explicitly asks only for a "占位实现" (placeholder
/// implementation) at this stage, with truncation as the real MVP
/// mechanism. A real `LLMService`-backed summarizer can conform to
/// `ChatHistorySummarizer` later and swap in wherever this one is used,
/// without touching any other call site.
public struct UnimplementedChatHistorySummarizer: ChatHistorySummarizer {
    public init() {}

    public func summarize(messages: [ChatMessage], previousSummary: String?) async throws -> String {
        throw ChatHistorySummarizerError.notImplemented
    }
}
