import Foundation

/// Second `LLMService` conformer — Anthropic's native Messages API
/// (no SDK, plain `URLSession`), so a Claude model can be selected as an
/// alternative to the OpenAI-compatible `/chat/completions` wire format
/// (S19 T4.1). Mirrors `OpenAICompatibleLLMService`'s behavior (tool round,
/// sentiment-factor formatting, plain + event streaming) — only the wire
/// format differs:
/// - `x-api-key` header (not `Authorization: Bearer`), plus `anthropic-version`.
/// - `system` is a top-level string field, not a `{role:"system"}` message.
/// - Tool calls come back as `{"type":"tool_use","id","name","input"}` content
///   blocks; results are fed back as a user message containing
///   `{"type":"tool_result","tool_use_id","content"}` blocks.
/// - SSE frames are `content_block_delta` (`delta.type=="text_delta"` ->
///   `delta.text`) and `message_stop` (end of stream).
public actor AnthropicLLMService: LLMService {

    public struct Configuration: Sendable {
        public var endpoint: URL
        public var model: String
        public var timeoutSeconds: TimeInterval
        /// Required by the Messages API. 4.7+ model family callers should not
        /// also pass `temperature`/`top_p`/`top_k` (this service never does).
        public var maxTokens: Int
        /// Same on-device `web_search` tool round as
        /// `OpenAICompatibleLLMService.Configuration.webSearch` — Claude's
        /// own retrieval isn't used here, this app's mx-search round is.
        public var webSearch: WebSearchToolOptions?

        public init(
            endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
            model: String,
            timeoutSeconds: TimeInterval = 180,
            maxTokens: Int = 4096,
            webSearch: WebSearchToolOptions? = nil
        ) {
            self.endpoint = endpoint
            self.model = model
            self.timeoutSeconds = timeoutSeconds
            self.maxTokens = maxTokens
            self.webSearch = webSearch
        }
    }

    private static let anthropicVersion = "2023-06-01"

    private let configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func generate(system: String, user: String) async throws -> String {
        let apiKey = try loadAPIKey()

        if let webSearch = configuration.webSearch {
            return try await runToolRound(system: system, user: user, apiKey: apiKey, webSearch: webSearch)
        }

        let data = try await sendMessages(
            system: system,
            messages: [["role": "user", "content": user]],
            tools: nil,
            apiKey: apiKey
        )
        return try Self.extractContent(from: data)
    }

    // MARK: - API key (same Keychain entry as the OpenAI-compatible service —
    // only one LLM provider is configured at a time, selected by `apiProtocol`)

    private func loadAPIKey() throws -> String {
        do {
            guard let storedKey = try LLMAPIKeyStore.load(), !storedKey.isEmpty else {
                throw LLMServiceError.notConfigured
            }
            return storedKey
        } catch let error as LLMServiceError {
            throw error
        } catch {
            throw LLMServiceError.unknown("keychain access failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Shared request sender

    private func sendMessages(system: String, messages: [[String: Any]], tools: [[String: Any]]?, apiKey: String) async throws -> Data {
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": configuration.maxTokens,
            "system": system,
            "messages": messages,
        ]
        if let tools {
            body["tools"] = tools
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw LLMServiceError.timeout
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

    // MARK: - Tool round (non-streaming)

    private func runToolRound(system: String, user: String, apiKey: String, webSearch: WebSearchToolOptions) async throws -> String {
        var messages: [[String: Any]] = [["role": "user", "content": user]]
        let tools = [Self.webSearchToolSchema()]

        for _ in 0..<max(1, webSearch.maxRounds) {
            let data = try await sendMessages(system: system, messages: messages, tools: tools, apiKey: apiKey)
            guard let content = Self.messageContent(from: data) else {
                throw LLMServiceError.invalidResponse("missing content array")
            }

            let toolUses = Self.toolUseBlocks(content)
            if toolUses.isEmpty {
                let text = Self.textFrom(content)
                guard !text.isEmpty else { throw LLMServiceError.emptyOutput }
                return text
            }

            messages.append(["role": "assistant", "content": content])
            messages.append(["role": "user", "content": try await toolResultBlocks(for: toolUses, webSearch: webSearch)])
        }

        // Rounds exhausted — one final call without tools to force an answer.
        let data = try await sendMessages(system: system, messages: messages, tools: nil, apiKey: apiKey)
        return try Self.extractContent(from: data)
    }

    private func toolResultBlocks(for toolUses: [[String: Any]], webSearch: WebSearchToolOptions) async throws -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        for block in toolUses {
            let id = (block["id"] as? String) ?? ""
            let query = Self.toolUseQuery(block) ?? ""
            let resultText: String
            if query.isEmpty {
                resultText = "（未提供搜索关键词）"
            } else {
                do {
                    let results = try await webSearch.service.search(query)
                    resultText = SearchResultFormatting.format(results)
                } catch {
                    resultText = "检索失败：\(error.localizedDescription)。请基于本地数据作答，并说明未能联网检索。"
                }
            }
            blocks.append(["type": "tool_result", "tool_use_id": id, "content": resultText])
        }
        return blocks
    }

    static func webSearchToolSchema() -> [String: Any] {
        [
            "name": "web_search",
            "description": "检索该股票的最新新闻、公告与市场舆情，返回标题、机构、评级与摘要。用于补充本地拿不到的新闻/公告/舆情维度。",
            "input_schema": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "搜索关键词，通常是股票名称/代码加上想了解的方面（如“贵州茅台 最新公告”“茅台 舆情 利空”）。",
                    ],
                ],
                "required": ["query"],
            ],
        ]
    }

    nonisolated static func messageContent(from data: Data) -> [[String: Any]]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            return nil
        }
        return content
    }

    nonisolated static func toolUseBlocks(_ content: [[String: Any]]) -> [[String: Any]] {
        content.filter { ($0["type"] as? String) == "tool_use" }
    }

    /// Extracts the `query` argument from a `tool_use` block's `input` object.
    nonisolated static func toolUseQuery(_ block: [String: Any]) -> String? {
        guard let input = block["input"] as? [String: Any] else { return nil }
        return input["query"] as? String
    }

    nonisolated static func textFrom(_ content: [[String: Any]]) -> String {
        content.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined()
    }

    // MARK: - Plain streaming (`streamGenerate`)

    public nonisolated func streamGenerate(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        // Same reasoning as `OpenAICompatibleLLMService.streamGenerate`: the
        // tool round needs full round-trips, which don't map onto a token
        // stream, so it falls back to the non-streamed `generate` wrapped as
        // one chunk. `streamGenerateEvents` below is the real streaming path
        // when a tool round is active.
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
                    let apiKey = try await loadAPIKey()
                    try await streamMessages(
                        system: system,
                        messages: [["role": "user", "content": user]],
                        tools: nil,
                        apiKey: apiKey
                    ) { text in continuation.yield(text) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Event stream (thinking events + streamed answer)

    public nonisolated func streamGenerateEvents(system: String, user: String) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runEvents(system: system, user: user, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runEvents(
        system: String,
        user: String,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        let apiKey = try loadAPIKey()

        guard let webSearch = configuration.webSearch else {
            try await streamMessages(
                system: system,
                messages: [["role": "user", "content": user]],
                tools: nil,
                apiKey: apiKey
            ) { text in continuation.yield(.answerDelta(text)) }
            return
        }

        var messages: [[String: Any]] = [["role": "user", "content": user]]
        let tools = [Self.webSearchToolSchema()]

        roundLoop: for _ in 0..<max(1, webSearch.maxRounds) {
            let data = try await sendMessages(system: system, messages: messages, tools: tools, apiKey: apiKey)
            guard let content = Self.messageContent(from: data) else {
                throw LLMServiceError.invalidResponse("missing content array")
            }

            let toolUses = Self.toolUseBlocks(content)
            if toolUses.isEmpty {
                break roundLoop
            }

            messages.append(["role": "assistant", "content": content])

            var resultBlocks: [[String: Any]] = []
            for block in toolUses {
                let id = (block["id"] as? String) ?? ""
                let query = Self.toolUseQuery(block) ?? ""
                let resultText: String
                if query.isEmpty {
                    resultText = "（未提供搜索关键词）"
                } else {
                    continuation.yield(.searching(query: query))
                    do {
                        let results = try await webSearch.service.search(query)
                        continuation.yield(.searchDone(summary: SearchResultFormatting.summaryLine(results)))
                        resultText = SearchResultFormatting.format(results)
                    } catch {
                        resultText = "检索失败：\(error.localizedDescription)。请基于本地数据作答，并说明未能联网检索。"
                        continuation.yield(.searchDone(summary: resultText))
                    }
                }
                resultBlocks.append(["type": "tool_result", "tool_use_id": id, "content": resultText])
            }
            messages.append(["role": "user", "content": resultBlocks])
        }

        // Model stopped asking for tools, or rounds ran out — force the
        // final answer with one streamed, tool-free request.
        try await streamMessages(system: system, messages: messages, tools: nil, apiKey: apiKey) { text in
            continuation.yield(.answerDelta(text))
        }
    }

    /// Shared SSE request body for both streaming entry points — takes a
    /// plain closure rather than either continuation type so it works for
    /// both `streamGenerate` (String) and `streamGenerateEvents` (LLMStreamEvent).
    private func streamMessages(
        system: String,
        messages: [[String: Any]],
        tools: [[String: Any]]?,
        apiKey: String,
        onDelta: (String) -> Void
    ) async throws {
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": configuration.maxTokens,
            "system": system,
            "messages": messages,
            "stream": true,
        ]
        if let tools {
            body["tools"] = tools
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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
                onDelta(text)
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

    nonisolated static func error(forStatusCode statusCode: Int, body: Data) -> LLMServiceError? {
        LLMServiceError.mapped(forStatusCode: statusCode, body: body)
    }

    /// Parses `{content:[{type,text}]}`. `type=="tool_use"` blocks are
    /// filtered out here; only `"text"` blocks are joined.
    nonisolated static func extractContent(from data: Data) throws -> String {
        guard let content = messageContent(from: data) else {
            throw LLMServiceError.invalidResponse("missing content array")
        }
        let text = textFrom(content)
        guard !text.isEmpty else {
            throw LLMServiceError.emptyOutput
        }
        return text
    }

    enum SSEEvent: Equatable {
        case delta(String)
        case done
    }

    /// Parses a single line read from an Anthropic Messages API SSE body.
    /// Frames of interest: `content_block_delta` with `delta.type=="text_delta"`
    /// (-> `.delta(text)`), and `message_stop` (-> `.done`). Every other frame
    /// (`message_start`, `content_block_start`, `ping`, `message_delta`,
    /// `content_block_stop`) carries nothing we need, so it's `nil` — one
    /// uninteresting frame shouldn't abort the rest of the stream.
    nonisolated static func parseSSEDataLine(_ line: String) -> SSEEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty,
              let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }
        switch type {
        case "content_block_delta":
            guard let delta = json["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty else {
                return nil
            }
            return .delta(text)
        case "message_stop":
            return .done
        default:
            return nil
        }
    }
}
