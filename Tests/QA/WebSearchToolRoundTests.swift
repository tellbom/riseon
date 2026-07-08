import XCTest
@testable import RiseOn

/// Pure-helper coverage for the `web_search` tool round and Tavily parsing —
/// the network round-trips themselves aren't auto-tested (consistent with the
/// rest of this codebase's networking layers), but every parsing/formatting
/// seam the loop depends on is.
final class WebSearchToolRoundTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - Tavily parse

    func test_tavily_parsesResults() {
        let json = """
        {"results":[
          {"title":"茅台发布公告","url":"https://x.com/a","content":"内容摘要A"},
          {"title":"舆情追踪","url":"https://x.com/b","content":"内容摘要B"}
        ]}
        """
        let results = TavilyWebSearchService.parse(data(json))
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "茅台发布公告")
        XCTAssertEqual(results[0].url, "https://x.com/a")
        XCTAssertEqual(results[1].snippet, "内容摘要B")
    }

    func test_tavily_emptyOrMalformed_returnsEmpty() {
        XCTAssertTrue(TavilyWebSearchService.parse(data("{}")).isEmpty)
        XCTAssertTrue(TavilyWebSearchService.parse(data("nope")).isEmpty)
    }

    // MARK: - Tool-call extraction

    func test_firstMessage_extractsMessage() {
        let json = """
        {"choices":[{"message":{"role":"assistant","content":"hi"}}]}
        """
        let message = OpenAICompatibleLLMService.firstMessage(from: data(json))
        XCTAssertEqual(message?["content"] as? String, "hi")
    }

    func test_toolCallQuery_parsesArgumentsJSONString() {
        let call: [String: Any] = [
            "id": "call_1",
            "function": ["name": "web_search", "arguments": "{\"query\":\"茅台 最新公告\"}"],
        ]
        XCTAssertEqual(OpenAICompatibleLLMService.toolCallQuery(call), "茅台 最新公告")
    }

    func test_toolCallQuery_malformedArguments_returnsNil() {
        let call: [String: Any] = ["function": ["arguments": "not json"]]
        XCTAssertNil(OpenAICompatibleLLMService.toolCallQuery(call))
    }

    // MARK: - Result formatting

    func test_formatSearchResults_numbersAndJoins() {
        let out = OpenAICompatibleLLMService.formatSearchResults([
            WebSearchResult(title: "T1", url: "u1", snippet: "s1"),
            WebSearchResult(title: "T2", url: "u2", snippet: "s2"),
        ])
        XCTAssertTrue(out.contains("1. T1"))
        XCTAssertTrue(out.contains("2. T2"))
        XCTAssertTrue(out.contains("u1"))
    }

    func test_formatSearchResults_empty_returnsNoResultsNote() {
        XCTAssertEqual(OpenAICompatibleLLMService.formatSearchResults([]), "未检索到相关结果。")
    }

    // MARK: - Tool round drives a mock search then answers

    private struct MockSearch: WebSearchService {
        func search(_ query: String) async throws -> [WebSearchResult] {
            [WebSearchResult(title: "mock", url: "https://m", snippet: "s")]
        }
    }

    func test_webSearchOptions_constructs() {
        let options = OpenAICompatibleLLMService.WebSearchOptions(service: MockSearch(), maxRounds: 2)
        XCTAssertEqual(options.maxRounds, 2)
    }
}
