import XCTest
@testable import RiseOn

/// Pure-helper coverage for `AnthropicLLMService` (S19 T4) — same scope
/// discipline as `LLMServiceTests`/`WebSearchToolRoundTests`: the actual
/// network round-trip isn't unit tested, but every parsing/mapping seam the
/// Messages API wire format depends on is (status-code mapping, tool_use
/// block extraction, `content_block_delta`/`message_stop` SSE parsing).
final class AnthropicLLMServiceTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    func test_defaultConfiguration_allowsSlowToolRoundFinalAnswer() {
        let configuration = AnthropicLLMService.Configuration(model: "claude-sonnet-4-6")
        XCTAssertGreaterThanOrEqual(configuration.timeoutSeconds, 180)
    }

    // MARK: - Status-code mapping (shared with OpenAICompatibleLLMService via LLMServiceError.mapped)

    func test_statusCode2xx_mapsToNoError() {
        XCTAssertNil(AnthropicLLMService.error(forStatusCode: 200, body: Data()))
    }

    func test_statusCode401_mapsToUnauthorized() {
        XCTAssertEqual(AnthropicLLMService.error(forStatusCode: 401, body: Data()), .unauthorized)
    }

    func test_statusCode429_mapsToRateLimited() {
        XCTAssertEqual(AnthropicLLMService.error(forStatusCode: 429, body: Data()), .rateLimited)
    }

    func test_statusCode5xx_mapsToServerErrorWithBodyMessage() {
        let body = "overloaded".data(using: .utf8)!
        XCTAssertEqual(
            AnthropicLLMService.error(forStatusCode: 529, body: body),
            .serverError(statusCode: 529, message: "overloaded")
        )
    }

    // MARK: - content extraction

    func test_extractContent_textBlock_returnsJoinedText() throws {
        let json = #"{"content":[{"type":"text","text":"这是回答"}]}"#
        let content = try AnthropicLLMService.extractContent(from: data(json))
        XCTAssertEqual(content, "这是回答")
    }

    func test_extractContent_multipleTextBlocks_joinsThem() throws {
        let json = #"{"content":[{"type":"text","text":"A"},{"type":"text","text":"B"}]}"#
        let content = try AnthropicLLMService.extractContent(from: data(json))
        XCTAssertEqual(content, "AB")
    }

    func test_extractContent_missingContentKey_throwsInvalidResponse() {
        XCTAssertThrowsError(try AnthropicLLMService.extractContent(from: data(#"{"unexpected":"shape"}"#))) { error in
            guard case LLMServiceError.invalidResponse = error else {
                return XCTFail("expected .invalidResponse, got \(error)")
            }
        }
    }

    func test_extractContent_onlyToolUseBlocks_throwsEmptyOutput() {
        let json = #"{"content":[{"type":"tool_use","id":"t1","name":"web_search","input":{"query":"茅台"}}]}"#
        XCTAssertThrowsError(try AnthropicLLMService.extractContent(from: data(json))) { error in
            guard case LLMServiceError.emptyOutput = error else {
                return XCTFail("expected .emptyOutput, got \(error)")
            }
        }
    }

    // MARK: - tool_use block extraction

    func test_toolUseBlocks_filtersOnlyToolUseType() {
        let content: [[String: Any]] = [
            ["type": "text", "text": "thinking out loud"],
            ["type": "tool_use", "id": "t1", "name": "web_search", "input": ["query": "茅台 最新公告"]],
        ]
        let toolUses = AnthropicLLMService.toolUseBlocks(content)
        XCTAssertEqual(toolUses.count, 1)
        XCTAssertEqual(toolUses[0]["id"] as? String, "t1")
    }

    func test_toolUseQuery_extractsQueryFromInput() {
        let block: [String: Any] = ["type": "tool_use", "input": ["query": "茅台 舆情"]]
        XCTAssertEqual(AnthropicLLMService.toolUseQuery(block), "茅台 舆情")
    }

    func test_toolUseQuery_missingInput_returnsNil() {
        XCTAssertNil(AnthropicLLMService.toolUseQuery(["type": "tool_use"]))
    }

    // MARK: - SSE line parsing

    func test_parseSSEDataLine_textDelta_returnsDelta() {
        let line = #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"你好"}}"#
        XCTAssertEqual(AnthropicLLMService.parseSSEDataLine(line), .delta("你好"))
    }

    func test_parseSSEDataLine_messageStop_returnsDone() {
        let line = #"data: {"type":"message_stop"}"#
        XCTAssertEqual(AnthropicLLMService.parseSSEDataLine(line), .done)
    }

    func test_parseSSEDataLine_pingOrMessageDelta_returnsNil() {
        XCTAssertNil(AnthropicLLMService.parseSSEDataLine(#"data: {"type":"ping"}"#))
        XCTAssertNil(AnthropicLLMService.parseSSEDataLine(#"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#))
        XCTAssertNil(AnthropicLLMService.parseSSEDataLine(#"data: {"type":"content_block_start"}"#))
    }

    func test_parseSSEDataLine_malformedJSON_returnsNil() {
        XCTAssertNil(AnthropicLLMService.parseSSEDataLine("data: not json"))
    }

    func test_parseSSEDataLine_nonDataLine_returnsNil() {
        XCTAssertNil(AnthropicLLMService.parseSSEDataLine(": keep-alive"))
        XCTAssertNil(AnthropicLLMService.parseSSEDataLine(""))
    }

    // MARK: - tool schema shape (name/required query param, needed for the tool round to work at all)

    func test_webSearchToolSchema_hasNameAndRequiredQuery() {
        let schema = AnthropicLLMService.webSearchToolSchema()
        XCTAssertEqual(schema["name"] as? String, "web_search")
        let inputSchema = schema["input_schema"] as? [String: Any]
        XCTAssertEqual(inputSchema?["required"] as? [String], ["query"])
    }
}
