import Foundation

/// One web-search result the LLM's `web_search` tool round can cite.
///
/// The sentiment-factor fields (`rating`/`institution`/`date`/
/// `informationType`/`indexAttention`) are populated by `MXSearchService`
/// (东方财富妙想 mx-search returns research-note/announcement metadata, not
/// just title+snippet); they default to `nil`/`false` for any other
/// `WebSearchService` backend, which simply won't get a ratings-distribution
/// summary line out of `SearchResultFormatting`.
public struct WebSearchResult: Equatable, Sendable {
    public var title: String
    public var url: String
    public var snippet: String
    public var rating: String?
    public var institution: String?
    public var date: String?
    public var informationType: String?
    public var indexAttention: Bool

    public init(
        title: String,
        url: String,
        snippet: String,
        rating: String? = nil,
        institution: String? = nil,
        date: String? = nil,
        informationType: String? = nil,
        indexAttention: Bool = false
    ) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.rating = rating
        self.institution = institution
        self.date = date
        self.informationType = informationType
        self.indexAttention = indexAttention
    }
}

/// Executes a single web search on-device — the tool the LLM calls when the
/// user has enabled 联网检索 but their chat model isn't itself search-
/// augmented. A pluggable seam (protocol) so a different search backend can
/// be dropped in, and so the tool round is unit-testable with a mock instead
/// of a live search call — same pattern as `LLMService`/`DailyBarsProvider`.
public protocol WebSearchService: Sendable {
    func search(_ query: String) async throws -> [WebSearchResult]
}

/// Options for the `web_search` tool round, shared by every direct-HTTP
/// `LLMService` conformer (`OpenAICompatibleLLMService`, `AnthropicLLMService`)
/// so the same on-device search backend and round-count knob plug into
/// either wire format identically.
public struct WebSearchToolOptions: Sendable {
    public var service: any WebSearchService
    public var maxRounds: Int

    public init(service: any WebSearchService, maxRounds: Int = 3) {
        self.service = service
        self.maxRounds = maxRounds
    }
}

/// Formats `web_search` tool results for hand-back to the model: a
/// sentiment-factor summary line (rating distribution + institution
/// coverage + high-attention count) followed by per-item detail, so the
/// model reasons over 情绪面因子 rather than raw text.
public enum SearchResultFormatting {
    private static let bullishKeywords = ["增持", "买入", "强推", "强烈推荐", "跑赢行业"]
    private static let bearishKeywords = ["下调", "减持", "回避"]

    /// Full tool-result body: summary line + numbered detail list.
    public nonisolated static func format(_ results: [WebSearchResult]) -> String {
        guard !results.isEmpty else { return "未检索到相关结果。" }
        return summaryLine(results) + "\n\n" + results.enumerated().map { index, result in
            detailLine(index: index, result: result)
        }.joined(separator: "\n\n")
    }

    /// Just the one-sentence sentiment summary — used as the `.searchDone`
    /// streaming event's payload, separate from the full detail list.
    public nonisolated static func summaryLine(_ results: [WebSearchResult]) -> String {
        guard !results.isEmpty else { return "未检索到相关结果。" }

        var bullishCounts: [String: Int] = [:]
        var bullishTotal = 0
        var bearishCount = 0
        for result in results {
            guard let rating = result.rating, !rating.isEmpty else { continue }
            if let keyword = bullishKeywords.first(where: { rating.contains($0) }) {
                bullishCounts[keyword, default: 0] += 1
                bullishTotal += 1
            } else if bearishKeywords.contains(where: { rating.contains($0) }) {
                bearishCount += 1
            }
        }
        let institutionCount = Set(results.compactMap { $0.institution }.filter { !$0.isEmpty }).count
        let attentionCount = results.filter { $0.indexAttention }.count

        var line = "本轮检索 \(results.count) 条研报/资讯"
        if bullishTotal > 0 {
            let breakdown = bullishKeywords.compactMap { keyword -> String? in
                guard let count = bullishCounts[keyword], count > 0 else { return nil }
                return "\(keyword)\(count)"
            }.joined(separator: "/")
            line += "：\(bullishTotal) 条看多(\(breakdown))"
            if bearishCount > 0 { line += "，\(bearishCount) 条看空" }
        } else if bearishCount > 0 {
            line += "：\(bearishCount) 条看空"
        } else {
            line += "，未见明确评级倾向"
        }
        if institutionCount > 0 {
            line += "，覆盖机构 \(institutionCount) 家"
        }
        if attentionCount > 0 {
            line += "，\(attentionCount) 条标注高关注度"
        }
        return line + "。"
    }

    private nonisolated static func detailLine(index: Int, result: WebSearchResult) -> String {
        var parts: [String] = ["\(index + 1). \(result.title)"]
        var meta: [String] = []
        if let institution = result.institution, !institution.isEmpty { meta.append(institution) }
        if let date = result.date, !date.isEmpty { meta.append(date) }
        if let rating = result.rating, !rating.isEmpty { meta.append(rating) }
        if let type = result.informationType, !type.isEmpty { meta.append(type) }
        if !meta.isEmpty { parts.append(meta.joined(separator: " | ")) }
        if !result.snippet.isEmpty { parts.append(result.snippet) }
        return parts.joined(separator: "\n")
    }
}

/// 东方财富妙想 mx-search (`POST /finskillshub/api/claw/news-search`) — the
/// `web_search` tool round's on-device search backend. Unlike a generic web
/// search API, mx-search returns research-note/announcement/news items with
/// institution + rating metadata, which is what lets `SearchResultFormatting`
/// build a 情绪面因子 summary instead of just relaying raw snippets.
public actor MXSearchService: WebSearchService {
    private static let endpoint = URL(string: "https://mkapi2.dfcfs.com/finskillshub/api/claw/news-search")!

    private let apiKey: String
    private let maxResults: Int
    private let session: URLSession

    public init(apiKey: String, maxResults: Int = 20, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.maxResults = maxResults
        self.session = session
    }

    public func search(_ query: String) async throws -> [WebSearchResult] {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw LLMServiceError.timeout
        } catch {
            throw LLMServiceError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LLMServiceError.serverError(statusCode: http.statusCode, message: String(data: data, encoding: .utf8))
        }
        guard Self.isSuccess(data) else {
            throw LLMServiceError.invalidResponse("mx-search 返回非成功状态")
        }
        let results = Self.parse(data)
        return maxResults > 0 ? Array(results.prefix(maxResults)) : results
    }

    /// Response shape: `{status:0 (or success:true), data:{data:{llmSearchResponse:{data:[...]}}}}`,
    /// each item carrying `title`/`content`/`date`/`informationType`/`insName`/
    /// `rating`/`indexAttention`/`secuCode`. Exposed for fixture tests (same
    /// pattern as `TencentQuoteProvider.parse`).
    public nonisolated static func parse(_ data: Data) -> [WebSearchResult] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outer = root["data"] as? [String: Any],
              let inner = outer["data"] as? [String: Any],
              let llmSearchResponse = inner["llmSearchResponse"] as? [String: Any],
              let items = llmSearchResponse["data"] as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let title = item["title"] as? String else { return nil }
            return WebSearchResult(
                title: title,
                url: (item["secuCode"] as? String) ?? "",
                snippet: (item["content"] as? String) ?? "",
                rating: item["rating"] as? String,
                institution: item["insName"] as? String,
                date: item["date"] as? String,
                informationType: item["informationType"] as? String,
                indexAttention: (item["indexAttention"] as? Bool) ?? false
            )
        }
    }

    private nonisolated static func isSuccess(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let status = root["status"] as? Int, status == 0 { return true }
        if let success = root["success"] as? Bool, success { return true }
        return false
    }
}
