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
        /// Optional `web_search` tool round. When set, `generate` lets the
        /// model call a search tool (executed on-device via `service`) up to
        /// `maxRounds` times before answering — used when 联网检索 is enabled
        /// but the chat model isn't itself search-augmented. `nil` (default)
        /// keeps the plain single-call behavior unchanged.
        public var webSearch: WebSearchOptions?

        public init(endpoint: URL, model: String, timeoutSeconds: TimeInterval = 60, webSearch: WebSearchOptions? = nil) {
            self.endpoint = endpoint
            self.model = model
            self.timeoutSeconds = timeoutSeconds
            self.webSearch = webSearch
        }
    }

    public struct WebSearchOptions: Sendable {
        public var service: any WebSearchService
        public var maxRounds: Int

        public init(service: any WebSearchService, maxRounds: Int = 3) {
            self.service = service
            self.maxRounds = maxRounds
        }
    }

    private let configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func generate(system: String, user: String) async throws -> String {
        let apiKey = try loadAPIKey()

        // Web-search tool round path (opt-in): let the model call `web_search`
        // and feed results back before it answers.
        if let webSearch = configuration.webSearch {
            return try await runToolRound(system: system, user: user, apiKey: apiKey, webSearch: webSearch)
        }

        let data = try await sendChat(
            messages: [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            tools: nil,
            apiKey: apiKey
        )
        return try Self.extractContent(from: data)
    }

    // MARK: - API key

    private func loadAPIKey() throws -> String {
        do {
            guard let storedKey = try LLMAPIKeyStore.load(), !storedKey.isEmpty else {
                throw LLMServiceError.notConfigured
            }
            return storedKey
        } catch let error as LLMServiceError {
            throw error
        } catch {
            // A genuine Keychain access failure (not "no key saved") -- still
            // surfaced through this type's own structured error, so callers
            // only ever need to handle one error type.
            throw LLMServiceError.unknown("keychain access failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Shared request sender

    /// Sends one chat-completions request (optionally with tools) and returns
    /// the raw response bytes, mapping non-2xx status to a structured error.
    private func sendChat(messages: [[String: Any]], tools: [[String: Any]]?, apiKey: String) async throws -> Data {
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = ["model": configuration.model, "messages": messages]
        if let tools {
            body["tools"] = tools
            body["tool_choice"] = "auto"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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
        return data
    }

    // MARK: - Tool round

    /// Runs the `web_search` function-calling loop: request with the tool
    /// exposed; if the model asks to search, execute each call on-device and
    /// feed results back; repeat up to `maxRounds`, then force a final answer.
    /// A single search failing isn't fatal — its result slot carries an error
    /// note so the model can still answer from the local data it was given.
    private func runToolRound(system: String, user: String, apiKey: String, webSearch: WebSearchOptions) async throws -> String {
        var messages: [[String: Any]] = [
            ["role": "system", "content": system],
            ["role": "user", "content": user],
        ]
        let tools = [Self.webSearchToolSchema()]

        for _ in 0..<max(1, webSearch.maxRounds) {
            let data = try await sendChat(messages: messages, tools: tools, apiKey: apiKey)
            guard let message = Self.firstMessage(from: data) else {
                throw LLMServiceError.invalidResponse("missing choices[0].message")
            }

            let toolCalls = message["tool_calls"] as? [[String: Any]] ?? []
            if toolCalls.isEmpty {
                if let content = message["content"] as? String, !content.isEmpty {
                    return content
                }
                throw LLMServiceError.emptyOutput
            }

            // Echo the assistant's tool-call message back, then answer each call.
            var assistantMessage: [String: Any] = ["role": "assistant", "tool_calls": toolCalls]
            if let content = message["content"] as? String { assistantMessage["content"] = content }
            messages.append(assistantMessage)

            for call in toolCalls {
                let id = (call["id"] as? String) ?? ""
                let query = Self.toolCallQuery(call) ?? ""
                let content: String
                if query.isEmpty {
                    content = "（未提供搜索关键词）"
                } else {
                    do {
                        let results = try await webSearch.service.search(query)
                        content = Self.formatSearchResults(results)
                    } catch {
                        content = "检索失败：\(error.localizedDescription)。请基于本地数据作答，并说明未能联网检索。"
                    }
                }
                messages.append(["role": "tool", "tool_call_id": id, "content": content])
            }
        }

        // Rounds exhausted — one final call without tools to force an answer.
        let data = try await sendChat(messages: messages, tools: nil, apiKey: apiKey)
        return try Self.extractContent(from: data)
    }

    static func webSearchToolSchema() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "web_search",
                "description": "检索该股票的最新新闻、公告与市场舆情，返回标题、链接与摘要。用于补充本地拿不到的新闻/公告/舆情维度。",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "搜索关键词，通常是股票名称/代码加上想了解的方面（如“贵州茅台 最新公告”“茅台 舆情 利空”）。",
                        ],
                    ],
                    "required": ["query"],
                ],
            ],
        ]
    }

    nonisolated static func firstMessage(from data: Data) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]], let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            return nil
        }
        return message
    }

    /// Extracts the `query` argument from a tool call's JSON-string arguments.
    nonisolated static func toolCallQuery(_ call: [String: Any]) -> String? {
        guard let function = call["function"] as? [String: Any],
              let arguments = function["arguments"] as? String,
              let argData = arguments.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: argData) as? [String: Any] else {
            return nil
        }
        return parsed["query"] as? String
    }

    nonisolated static func formatSearchResults(_ results: [WebSearchResult]) -> String {
        guard !results.isEmpty else { return "未检索到相关结果。" }
        return results.enumerated().map { index, result in
            "\(index + 1). \(result.title)\n\(result.url)\n\(result.snippet)"
        }.joined(separator: "\n\n")
    }

    public nonisolated func streamGenerate(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        // The tool round needs full round-trips (search → feed back → answer),
        // which don't map onto a token stream — so when web search is on, run
        // the non-streamed `generate` and yield its result as one chunk. The
        // chat UI already switches to the non-streaming `ask` path in this
        // case, so this branch is a safety net rather than the primary route.
        if configuration.webSearch != nil {
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let answer = try await generate(system: system, user: user)
                        continuation.yield(answer)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runStream(system: system, user: user, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStream(
        system: String,
        user: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let apiKey: String
        do {
            guard let storedKey = try LLMAPIKeyStore.load(), !storedKey.isEmpty else {
                throw LLMServiceError.notConfigured
            }
            apiKey = storedKey
        } catch let error as LLMServiceError {
            throw error
        } catch {
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
            "stream": true,
        ])

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
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

        if httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
            }
            throw Self.error(forStatusCode: httpResponse.statusCode, body: body) ?? .unknown("HTTP \(httpResponse.statusCode)")
        }

        var receivedAnyDelta = false
        for try await line in bytes.lines {
            switch Self.parseSSEDataLine(line) {
            case .delta(let text):
                receivedAnyDelta = true
                continuation.yield(text)
            case .done:
                return
            case nil:
                continue
            }
        }
        guard receivedAnyDelta else {
            throw LLMServiceError.emptyOutput
        }
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

    /// One decoded SSE `data:` event from a chat-completions stream.
    enum SSEEvent: Equatable {
        case delta(String)
        case done
    }

    /// Parses a single line read from an SSE body. Returns `nil` for lines
    /// that carry no content for us (blank keep-alive lines, malformed JSON,
    /// chunks with no `delta.content`) — the caller just skips those rather
    /// than treating them as fatal, since a stream is a sequence of frames
    /// and one uninteresting frame shouldn't abort the rest.
    nonisolated static func parseSSEDataLine(_ line: String) -> SSEEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty else { return nil }
        if payload == "[DONE]" {
            return .done
        }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]], let first = choices.first,
              let delta = first["delta"] as? [String: Any], let content = delta["content"] as? String,
              !content.isEmpty else {
            return nil
        }
        return .delta(content)
    }
}
