import Foundation

/// Non-secret LLM connection settings. The API key itself stays in
/// `LLMAPIKeyStore` (Keychain); endpoint/model are ordinary preferences.
public enum LLMConfigurationStore {
    private static let endpointKey = "llm.endpoint"
    private static let modelKey = "llm.model"
    private static let webSearchKey = "llm.webSearchEnabled"

    public struct Settings: Equatable, Sendable {
        public var endpoint: String
        public var model: String
        /// The configured model can retrieve web content — either it's a
        /// search-augmented model, or the `web_search` tool round is wired
        /// (a Tavily key is saved). Drives `PromptBuilder.Options` and whether
        /// `makeService` attaches the tool round. Off by default (strict
        /// offline behavior unchanged).
        public var webSearchEnabled: Bool

        public init(endpoint: String, model: String, webSearchEnabled: Bool = false) {
            self.endpoint = endpoint
            self.model = model
            self.webSearchEnabled = webSearchEnabled
        }

        public var isUsable: Bool {
            guard let url = URL(string: endpoint), url.scheme != nil, url.host != nil else {
                return false
            }
            return !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public static let defaults = Settings(
        endpoint: "https://api.openai.com/v1/chat/completions",
        model: "gpt-4o-mini"
    )

    /// Curated endpoint/model presets for the settings screen — including a
    /// search-augmented option (Perplexity `sonar`) so the user can enable
    /// news/公告/舆情 retrieval by switching model, with zero extra keys.
    public struct Preset: Identifiable, Equatable, Sendable {
        public var id: String { name }
        public let name: String
        public let endpoint: String
        public let model: String
        public let webCapable: Bool
        public let note: String
    }

    public static let presets: [Preset] = [
        Preset(name: "OpenAI · gpt-4o-mini", endpoint: "https://api.openai.com/v1/chat/completions", model: "gpt-4o-mini", webCapable: false, note: "通用、便宜，无联网"),
        Preset(name: "OpenAI · gpt-4o", endpoint: "https://api.openai.com/v1/chat/completions", model: "gpt-4o", webCapable: false, note: "更强，无联网"),
        Preset(name: "Perplexity · sonar", endpoint: "https://api.perplexity.ai/chat/completions", model: "sonar", webCapable: true, note: "自带联网检索，可补新闻/舆情"),
        Preset(name: "Perplexity · sonar-pro", endpoint: "https://api.perplexity.ai/chat/completions", model: "sonar-pro", webCapable: true, note: "联网 + 更强推理"),
        Preset(name: "DeepSeek · deepseek-chat", endpoint: "https://api.deepseek.com/v1/chat/completions", model: "deepseek-chat", webCapable: false, note: "中文友好，无联网"),
    ]

    public static func load(userDefaults: UserDefaults = .standard) -> Settings {
        Settings(
            endpoint: userDefaults.string(forKey: endpointKey) ?? defaults.endpoint,
            model: userDefaults.string(forKey: modelKey) ?? defaults.model,
            webSearchEnabled: userDefaults.bool(forKey: webSearchKey)
        )
    }

    public static func save(_ settings: Settings, userDefaults: UserDefaults = .standard) {
        userDefaults.set(settings.endpoint, forKey: endpointKey)
        userDefaults.set(settings.model, forKey: modelKey)
        userDefaults.set(settings.webSearchEnabled, forKey: webSearchKey)
    }

    public static func makeService(settings: Settings = load()) throws -> OpenAICompatibleLLMService {
        guard let endpoint = URL(string: settings.endpoint), settings.isUsable else {
            throw LLMServiceError.notConfigured
        }

        // Attach the `web_search` tool round only when the user both enabled
        // 联网检索 AND saved a search (Tavily) key. If web search is on but no
        // search key is saved, the model itself is expected to be search-
        // augmented (e.g. Perplexity sonar does its own retrieval) — so no
        // tool round is wired, the prompt just permits retrieval.
        var webSearch: OpenAICompatibleLLMService.WebSearchOptions?
        if settings.webSearchEnabled, let key = (try? WebSearchAPIKeyStore.load()) ?? nil, !key.isEmpty {
            webSearch = .init(service: TavilyWebSearchService(apiKey: key))
        }

        return OpenAICompatibleLLMService(configuration: .init(
            endpoint: endpoint,
            model: settings.model,
            webSearch: webSearch
        ))
    }
}
