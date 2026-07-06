import Foundation

/// Direct cloud implementation of `LLMService` (task.md S10.2): user's own
/// API key (Keychain via `LLMAPIKeyStore`, S3.2), talking straight to a
/// cloud endpoint — no server-side proxy.
///
/// **Wire format decision (flagged for review, not dictated by task.md):**
/// this speaks the OpenAI-compatible `/chat/completions` shape
/// (`{model, messages:[{role,content}]} -> {choices:[{message:{content}}]}`),
/// not Anthropic's native Messages API. That format is what the widest range
/// of providers a personal-use setup might point at actually implement
/// (OpenAI itself, and many OpenAI-compatible endpoints from other
/// providers) — configured via `Configuration.baseURL`/`model`, not
/// hardcoded to one vendor. If a different wire format is wanted instead,
/// add a second `LLMService` conformer alongside this one — nothing
/// upstream (`PromptBuilder`, the future chat UI) depends on which
/// concrete type is used, only on the `LLMService` protocol.
public actor OpenAICompatibleLLMService: LLMService {

    public struct Configuration: Sendable {
        /// Full chat-completions endpoint, e.g.
        /// `https://api.openai.com/v1/chat/completions`.
        public var endpoint: URL
        public var model: String
        public var timeoutSeconds: TimeInterval

        public init(endpoint: URL, model: String, timeoutSeconds: TimeInterval = 60) {
            self.endpoint = endpoint
            self.model = model
            self.timeoutSeconds = timeoutSeconds
        }
    }

    private let configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func generate(system: String, user: String) async throws -> String {
        let apiKey: String
        do {
            guard let storedKey = try LLMAPIKeyStore.load(), !storedKey.isEmpty else {
                throw LLMServiceError.notConfigured
            }
            apiKey = storedKey
        } catch let error as LLMServiceError {
            throw error
        } catch {
            // A genuine Keychain access failure (not "no key saved") -- still
            // surfaced through this type's own structured error, so callers
            // only ever need to handle one error type.
            throw LLMServiceError.unknown("keychain access failed: \(error.localizedDescription)")
        }

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": configuration.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw LLMServiceError.timeout
        } catch let error as URLError {
            throw LLMServiceError.network(error.localizedDescription)
        } catch {
            throw LLMServiceError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMServiceError.unknown("response was not an HTTP response")
        }

        if let mappedError = Self.error(forStatusCode: httpResponse.statusCode, body: data) {
            throw mappedError
        }

        return try Self.extractContent(from: data)
    }

    // MARK: - Pure helpers, exposed for fixture-based tests
    // (same reasoning as `TencentQuoteProvider.parse`/`TencentDailyProvider.parseBars`)

    /// Maps an HTTP status code to a structured error, or `nil` for 2xx.
    nonisolated static func error(forStatusCode statusCode: Int, body: Data) -> LLMServiceError? {
        switch statusCode {
        case 200..<300:
            return nil
        case 401, 403:
            return .unauthorized
        case 429:
            return .rateLimited
        default:
            // Covers 5xx plus any other non-2xx status the three named
            // cases above don't specifically call out (task.md only names
            // 超时/鉴权/空输出 — timeout/auth/empty-output — explicitly;
            // everything else still needs *a* clear error state rather than
            // being silently swallowed).
            return .serverError(statusCode: statusCode, message: String(data: body, encoding: .utf8))
        }
    }

    /// Parses `{choices:[{message:{content:String}}]}`, throwing a
    /// structured error rather than returning `nil`, so callers get a
    /// specific reason (`invalidResponse` vs `emptyOutput`) instead of a
    /// bare optional.
    nonisolated static func extractContent(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMServiceError.invalidResponse("response body is not valid JSON")
        }
        guard let choices = json["choices"] as? [[String: Any]], let first = choices.first,
              let message = first["message"] as? [String: Any], let content = message["content"] as? String else {
            throw LLMServiceError.invalidResponse("missing choices[0].message.content")
        }
        guard !content.isEmpty else {
            throw LLMServiceError.emptyOutput
        }
        return content
    }
}
