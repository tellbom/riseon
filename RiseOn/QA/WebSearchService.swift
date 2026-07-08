import Foundation

/// One web-search result the LLM's `web_search` tool round can cite.
public struct WebSearchResult: Equatable, Sendable {
    public var title: String
    public var url: String
    public var snippet: String

    public init(title: String, url: String, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
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

/// Tavily implementation (`https://api.tavily.com/search`) — a simple JSON
/// search API with a single key, no OAuth. Chosen as a concrete default
/// because it's the least-friction option for a personal-use setup; swap in
/// another `WebSearchService` conformer to use a different provider.
public actor TavilyWebSearchService: WebSearchService {
    private let apiKey: String
    private let maxResults: Int
    private let session: URLSession

    public init(apiKey: String, maxResults: Int = 5, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.maxResults = maxResults
        self.session = session
    }

    public func search(_ query: String) async throws -> [WebSearchResult] {
        guard let url = URL(string: "https://api.tavily.com/search") else {
            throw LLMServiceError.network("invalid search URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "api_key": apiKey,
            "query": query,
            "search_depth": "basic",
            "max_results": maxResults,
            "include_answer": false,
        ])

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
        return Self.parse(data)
    }

    /// Response: `{results:[{title,url,content}]}`. Exposed for fixture tests.
    public nonisolated static func parse(_ data: Data) -> [WebSearchResult] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            return []
        }
        return results.compactMap { row in
            guard let title = row["title"] as? String,
                  let url = row["url"] as? String else { return nil }
            let snippet = (row["content"] as? String) ?? ""
            return WebSearchResult(title: title, url: url, snippet: snippet)
        }
    }
}
