import Foundation

/// Minimal generation protocol (task.md S10.1), aligned with the shape of
/// `src/llm/generation_backend.py::GenerationBackend.generate` but reduced
/// to what a single-turn Q&A prompt actually needs — this app has no
/// tool-calling, no JSON-schema validation, so those parameters are dropped
/// rather than carried along unused. `streamGenerate` was added on top of
/// the original one-shot `generate` once the chat UI needed token-level SSE
/// streaming to match normal web LLM chat interactions.
///
/// This is one of only two places network I/O is allowed (the other being
/// `QuoteProvider`/`TencentDailyProvider`) — see plan.md §13's "纪律".
///
/// Being a plain protocol (not tied to any concrete backend) is what task.md
/// S10.1's verification point asks for: any conformer, including a test
/// mock, can stand in wherever `LLMService` is required.
public protocol LLMService: Sendable {
    func generate(system: String, user: String) async throws -> String

    /// Streams the answer as it's generated, yielding incremental text
    /// chunks (not full-so-far snapshots — callers accumulate themselves).
    /// The stream finishes normally once the underlying response completes,
    /// or throws the same `LLMServiceError` cases `generate` would.
    func streamGenerate(system: String, user: String) -> AsyncThrowingStream<String, Error>

    /// Same as `streamGenerate`, but surfaces "thinking" events (the
    /// `web_search` tool round's searches) alongside the final answer's
    /// token stream — see `LLMStreamEvent`. The default implementation
    /// bridges `streamGenerate`'s plain text stream into `.answerDelta`
    /// events with no search events, so existing conformers keep working
    /// unchanged; concrete direct-HTTP services override this to interleave
    /// real `.searching`/`.searchDone` events around their tool round.
    func streamGenerateEvents(system: String, user: String) -> AsyncThrowingStream<LLMStreamEvent, Error>
}

public extension LLMService {
    func streamGenerateEvents(system: String, user: String) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await delta in streamGenerate(system: system, user: user) {
                        continuation.yield(.answerDelta(delta))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// One "thinking" or answer event from `LLMService.streamGenerateEvents` —
/// lets the chat UI show what the model is doing (which query it's
/// searching, what it found) instead of just a blank "typing…" indicator
/// during the `web_search` tool round.
public enum LLMStreamEvent: Sendable {
    /// The model is about to run one on-device search — its query, before
    /// the search executes.
    case searching(query: String)
    /// That search's sentiment-factor summary (one sentence), after it ran.
    case searchDone(summary: String)
    /// An incremental chunk of the final answer's token stream.
    case answerDelta(String)
}

public struct LLMStreamDiagnostics: Equatable, Sendable {
    public private(set) var startedAt: Date
    public private(set) var firstDeltaAt: Date?
    public private(set) var deltaCount: Int
    public private(set) var receivedCharacterCount: Int
    public private(set) var largestDeltaCharacterCount: Int

    public init(startedAt: Date = Date()) {
        self.startedAt = startedAt
        self.firstDeltaAt = nil
        self.deltaCount = 0
        self.receivedCharacterCount = 0
        self.largestDeltaCharacterCount = 0
    }

    public var secondsToFirstDelta: TimeInterval? {
        firstDeltaAt.map { $0.timeIntervalSince(startedAt) }
    }

    public var isLikelyBuffered: Bool {
        deltaCount == 1 && largestDeltaCharacterCount >= 800
    }

    public mutating func record(delta: String, receivedAt: Date = Date()) {
        if firstDeltaAt == nil {
            firstDeltaAt = receivedAt
        }
        let count = delta.count
        deltaCount += 1
        receivedCharacterCount += count
        largestDeltaCharacterCount = max(largestDeltaCharacterCount, count)
    }
}

/// Structured failure states (task.md S10.2), **inspired by** —not a literal
/// 1:1 port of— `GenerationErrorCode`. Most of that Python enum
/// (`COMMAND_NOT_FOUND`, `COMMAND_NOT_EXECUTABLE`, `INTERACTIVE_PROMPT_REQUIRED`,
/// `APPROVAL_REQUIRED`, `LOGIN_REQUIRED`, `UNSUPPORTED_TOOL_CALLING`,
/// `SCHEMA_VALIDATION_FAILED`) describes failure modes of a **local CLI
/// subprocess backend** (`local_cli_backend.py`) — they can't occur when
/// talking directly to a cloud HTTPS JSON API, so porting them verbatim
/// would just be dead cases. What's kept/added instead is the subset that
/// actually maps to a direct HTTP call, per task.md's own three named
/// examples (超时/鉴权/空输出 — timeout/auth/empty output) plus the real
/// failure modes an HTTP client sees that the Python enum doesn't need
/// (it delegates that layer to LiteLLM): `network`, `rateLimited`,
/// `serverError`.
public enum LLMServiceError: Error, Equatable, Sendable {
    /// No API key saved yet (`LLMAPIKeyStore.load()` returned `nil`) —
    /// mirrors `BACKEND_NOT_CONFIGURED`.
    case notConfigured
    /// HTTP 401/403 — the saved key was rejected.
    case unauthorized
    /// HTTP 429.
    case rateLimited
    /// Request exceeded its timeout — mirrors `TIMEOUT`.
    case timeout
    /// Connectivity failure below the HTTP layer (offline, DNS, TLS, etc.).
    case network(String)
    /// HTTP 5xx from the provider.
    case serverError(statusCode: Int, message: String?)
    /// 2xx response, but not shaped like a chat-completion we can parse.
    case invalidResponse(String)
    /// Parsed successfully, but the model returned nothing — mirrors `EMPTY_OUTPUT`.
    case emptyOutput
    /// Catch-all — mirrors `UNKNOWN_BACKEND_ERROR`.
    case unknown(String)
}

public extension LLMServiceError {
    /// Maps an HTTP status code to a structured error, or `nil` for 2xx —
    /// shared by every direct-HTTP `LLMService` conformer (OpenAI-compatible,
    /// Anthropic) so the same three named failure modes (超时/鉴权/空输出, plus
    /// the real HTTP-layer failures a Python `LiteLLM`-backed enum doesn't
    /// need: network/rateLimited/serverError) map identically regardless of
    /// wire format.
    static func mapped(forStatusCode statusCode: Int, body: Data) -> LLMServiceError? {
        switch statusCode {
        case 200..<300:
            return nil
        case 401, 403:
            return .unauthorized
        case 429:
            return .rateLimited
        default:
            return .serverError(statusCode: statusCode, message: String(data: body, encoding: .utf8))
        }
    }
}

extension LLMServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "尚未配置 LLM API Key，请先在设置里填写。"
        case .unauthorized:
            return "API Key 无效或已被拒绝，请检查后重试。"
        case .rateLimited:
            return "请求过于频繁，被服务端限流，请稍后重试。"
        case .timeout:
            return "请求超时，请检查网络后重试。"
        case .network(let detail):
            return "网络连接失败：\(detail)"
        case .serverError(let statusCode, let message):
            return "服务端返回错误（HTTP \(statusCode)）：\(message ?? "无详情")"
        case .invalidResponse(let detail):
            return "无法解析模型返回内容：\(detail)"
        case .emptyOutput:
            return "模型没有返回任何内容。"
        case .unknown(let detail):
            return "未知错误：\(detail)"
        }
    }
}
