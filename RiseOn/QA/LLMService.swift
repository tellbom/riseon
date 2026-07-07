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
