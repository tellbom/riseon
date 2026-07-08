import XCTest
@testable import RiseOn

/// Pure-helper coverage for the `web_search` tool round and mx-search
/// (东方财富妙想) parsing/formatting — the network round-trips themselves
/// aren't auto-tested (consistent with the rest of this codebase's
/// networking layers), but every parsing/formatting seam the loop depends
/// on is.
final class WebSearchToolRoundTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - mx-search parse

    func test_mxSearch_parsesResults() {
        let json = """
        {"status":0,"data":{"data":{"llmSearchResponse":{"data":[
          {"title":"贵州茅台点评","content":"内容摘要A","date":"2026-07-01","informationType":"研报","insName":"某券商","rating":"买入","indexAttention":true,"secuCode":"600519"},
          {"title":"舆情追踪","content":"内容摘要B","date":"2026-07-02","informationType":"资讯","insName":"另一机构","rating":"减持","indexAttention":false}
        ]}}}}
        """
        let results = MXSearchService.parse(data(json))
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "贵州茅台点评")
        XCTAssertEqual(results[0].institution, "某券商")
        XCTAssertEqual(results[0].rating, "买入")
        XCTAssertTrue(results[0].indexAttention)
        XCTAssertEqual(results[1].snippet, "内容摘要B")
        XCTAssertFalse(results[1].indexAttention)
    }

    func test_mxSearch_emptyOrMalformed_returnsEmpty() {
        XCTAssertTrue(MXSearchService.parse(data("{}")).isEmpty)
        XCTAssertTrue(MXSearchService.parse(data("nope")).isEmpty)
    }

    // MARK: - Tool-call extraction (OpenAI-compatible wire format, unaffected by the search backend swap)

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

    // MARK: - Sentiment-factor result formatting

    func test_formatSearchResults_numbersAndIncludesSentimentMeta() {
        let out = OpenAICompatibleLLMService.formatSearchResults([
            WebSearchResult(title: "T1", url: "", snippet: "s1", rating: "买入", institution: "机构A", date: "2026-07-01"),
            WebSearchResult(title: "T2", url: "", snippet: "s2", rating: "减持", institution: "机构B", date: "2026-07-02"),
        ])
        XCTAssertTrue(out.contains("1. T1"))
        XCTAssertTrue(out.contains("2. T2"))
        XCTAssertTrue(out.contains("机构A"))
        XCTAssertTrue(out.contains("买入"))
        XCTAssertTrue(out.contains("s1"))
    }

    func test_formatSearchResults_empty_returnsNoResultsNote() {
        XCTAssertEqual(OpenAICompatibleLLMService.formatSearchResults([]), "未检索到相关结果。")
    }

    func test_summaryLine_classifiesBullishAndBearish() {
        let summary = SearchResultFormatting.summaryLine([
            WebSearchResult(title: "T1", url: "", snippet: "", rating: "买入", institution: "机构A", indexAttention: true),
            WebSearchResult(title: "T2", url: "", snippet: "", rating: "增持", institution: "机构B"),
            WebSearchResult(title: "T3", url: "", snippet: "", rating: "减持", institution: "机构A"),
        ])
        XCTAssertTrue(summary.contains("2 条看多"))
        XCTAssertTrue(summary.contains("1 条看空"))
        XCTAssertTrue(summary.contains("覆盖机构 2 家"))
        XCTAssertTrue(summary.contains("1 条标注高关注度"))
    }

    func test_summaryLine_empty_returnsNoResultsNote() {
        XCTAssertEqual(SearchResultFormatting.summaryLine([]), "未检索到相关结果。")
    }

    // MARK: - Tool round drives a mock search then answers

    private struct MockSearch: WebSearchService {
        func search(_ query: String) async throws -> [WebSearchResult] {
            [WebSearchResult(title: "mock", url: "https://m", snippet: "s")]
        }
    }

    func test_webSearchToolOptions_constructs() {
        let options = WebSearchToolOptions(service: MockSearch(), maxRounds: 2)
        XCTAssertEqual(options.maxRounds, 2)
    }
}
