import Foundation

/// Non-secret LLM connection settings. The API key itself stays in
/// `LLMAPIKeyStore` (Keychain); endpoint/model are ordinary preferences.
public enum LLMConfigurationStore {
    private static let endpointKey = "llm.endpoint"
    private static let modelKey = "llm.model"
    private static let webSearchKey = "llm.webSearchEnabled"
    private static let apiProtocolKey = "llm.apiProtocol"

    /// Which wire format `makeService` talks: OpenAI-compatible
    /// `/chat/completions`, or Anthropic's native Messages API.
    public enum WireProtocol: String, Equatable, Sendable, CaseIterable {
        case openai
        case anthropic
    }

    public struct Settings: Equatable, Sendable {
        public var endpoint: String
        public var model: String
        /// The configured model can retrieve web content — either it's a
        /// search-augmented model, or the `web_search` tool round is wired
        /// (an MX 妙想 key is saved). Drives `PromptBuilder.Options` and
        /// whether `makeService` attaches the tool round. Off by default
        /// (strict offline behavior unchanged).
        public var webSearchEnabled: Bool
        public var apiProtocol: WireProtocol

        public init(endpoint: String, model: String, webSearchEnabled: Bool = false, apiProtocol: WireProtocol = .openai) {
            self.endpoint = endpoint
            self.model = model
            self.webSearchEnabled = webSearchEnabled
            self.apiProtocol = apiProtocol
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
    /// news/公告/舆情 retrieval by switching model, with zero extra keys, and
    /// two Claude (Anthropic Messages API) presets. Claude's own web
    /// retrieval isn't wired here (`webCapable: false`) — its 联网检索 goes
    /// through the same on-device mx-search tool round as the OpenAI-
    /// compatible presets.
    public struct Preset: Identifiable, Equatable, Sendable {
        public var id: String { name }
        public let name: String
        public let endpoint: String
        public let model: String
        public let webCapable: Bool
        public let note: String
        public let apiProtocol: WireProtocol

        public init(name: String, endpoint: String, model: String, webCapable: Bool, note: String, apiProtocol: WireProtocol = .openai) {
            self.name = name
            self.endpoint = endpoint
            self.model = model
            self.webCapable = webCapable
            self.note = note
            self.apiProtocol = apiProtocol
        }
    }

    /// Claude presets need `apiProtocol: .anthropic` — the only difference
    /// from the OpenAI-compatible preset constructor call above.
    private static func claudePreset(name: String, model: String, note: String) -> Preset {
        Preset(
            name: name,
            endpoint: "https://api.anthropic.com/v1/messages",
            model: model,
            webCapable: false,
            note: note,
            apiProtocol: .anthropic
        )
    }

    public static let presets: [Preset] = [
        Preset(name: "OpenAI · gpt-4o-mini", endpoint: "https://api.openai.com/v1/chat/completions", model: "gpt-4o-mini", webCapable: false, note: "通用、便宜，无联网"),
        Preset(name: "OpenAI · gpt-4o", endpoint: "https://api.openai.com/v1/chat/completions", model: "gpt-4o", webCapable: false, note: "更强，无联网"),
        Preset(name: "Perplexity · sonar", endpoint: "https://api.perplexity.ai/chat/completions", model: "sonar", webCapable: true, note: "自带联网检索，可补新闻/舆情"),
        Preset(name: "Perplexity · sonar-pro", endpoint: "https://api.perplexity.ai/chat/completions", model: "sonar-pro", webCapable: true, note: "联网 + 更强推理"),
        Preset(name: "DeepSeek · deepseek-chat", endpoint: "https://api.deepseek.com/v1/chat/completions", model: "deepseek-chat", webCapable: false, note: "中文友好，无联网"),
        claudePreset(name: "Anthropic · claude-sonnet-5", model: "claude-sonnet-5", note: "Claude，联网走本地 mx 检索"),
        claudePreset(name: "Anthropic · claude-opus-4-8", model: "claude-opus-4-8", note: "Claude 更强模型，联网走本地 mx 检索"),
    ]

    public static func load(userDefaults: UserDefaults = .standard) -> Settings {
        let apiProtocol = userDefaults.string(forKey: apiProtocolKey).flatMap(WireProtocol.init(rawValue:)) ?? .openai
        return Settings(
            endpoint: userDefaults.string(forKey: endpointKey) ?? defaults.endpoint,
            model: userDefaults.string(forKey: modelKey) ?? defaults.model,
            webSearchEnabled: userDefaults.bool(forKey: webSearchKey),
            apiProtocol: apiProtocol
        )
    }

    public static func save(_ settings: Settings, userDefaults: UserDefaults = .standard) {
        userDefaults.set(settings.endpoint, forKey: endpointKey)
        userDefaults.set(settings.model, forKey: modelKey)
        userDefaults.set(settings.webSearchEnabled, forKey: webSearchKey)
        userDefaults.set(settings.apiProtocol.rawValue, forKey: apiProtocolKey)
    }

    /// Builds the configured `LLMService` — `AnthropicLLMService` or
    /// `OpenAICompatibleLLMService`, chosen by `settings.apiProtocol`. The
    /// `web_search` tool round logic (attach when 联网检索 is on and an MX Key
    /// is saved) is identical for either wire format.
    public static func makeService(settings: Settings = load()) throws -> any LLMService {
        guard let endpoint = URL(string: settings.endpoint), settings.isUsable else {
            throw LLMServiceError.notConfigured
        }

        // Attach the `web_search` tool round only when the user both enabled
        // 联网检索 AND saved an MX 妙想 key. If web search is on but no search
        // key is saved, the model itself is expected to be search-augmented
        // (e.g. Perplexity sonar does its own retrieval) — so no tool round
        // is wired, the prompt just permits retrieval.
        var webSearch: WebSearchToolOptions?
        if settings.webSearchEnabled, let key = (try? WebSearchAPIKeyStore.load()) ?? nil, !key.isEmpty {
            webSearch = .init(service: MXSearchService(apiKey: key))
        }

        switch settings.apiProtocol {
        case .anthropic:
            return AnthropicLLMService(configuration: .init(endpoint: endpoint, model: settings.model, webSearch: webSearch))
        case .openai:
            return OpenAICompatibleLLMService(configuration: .init(endpoint: endpoint, model: settings.model, webSearch: webSearch))
        }
    }
}
