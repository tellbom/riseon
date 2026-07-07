import Foundation

/// Non-secret LLM connection settings. The API key itself stays in
/// `LLMAPIKeyStore` (Keychain); endpoint/model are ordinary preferences.
public enum LLMConfigurationStore {
    private static let endpointKey = "llm.endpoint"
    private static let modelKey = "llm.model"

    public struct Settings: Equatable, Sendable {
        public var endpoint: String
        public var model: String

        public init(endpoint: String, model: String) {
            self.endpoint = endpoint
            self.model = model
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

    public static func load(userDefaults: UserDefaults = .standard) -> Settings {
        Settings(
            endpoint: userDefaults.string(forKey: endpointKey) ?? defaults.endpoint,
            model: userDefaults.string(forKey: modelKey) ?? defaults.model
        )
    }

    public static func save(_ settings: Settings, userDefaults: UserDefaults = .standard) {
        userDefaults.set(settings.endpoint, forKey: endpointKey)
        userDefaults.set(settings.model, forKey: modelKey)
    }

    public static func makeService(settings: Settings = load()) throws -> OpenAICompatibleLLMService {
        guard let endpoint = URL(string: settings.endpoint), settings.isUsable else {
            throw LLMServiceError.notConfigured
        }
        return OpenAICompatibleLLMService(configuration: .init(endpoint: endpoint, model: settings.model))
    }
}
