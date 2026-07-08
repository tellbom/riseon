import XCTest
@testable import RiseOn

/// Covers S19 T4.2: protocol persistence and `makeService`'s branch between
/// `AnthropicLLMService`/`OpenAICompatibleLLMService` based on
/// `Settings.apiProtocol`. Uses an isolated `UserDefaults` suite so this
/// doesn't read/write the app's real saved settings.
final class LLMConfigurationStoreTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "LLMConfigurationStoreTests")
        suite.removePersistentDomain(forName: "LLMConfigurationStoreTests")
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: "LLMConfigurationStoreTests")
        suite = nil
        super.tearDown()
    }

    func test_load_withNothingSaved_defaultsToOpenAIProtocol() {
        let settings = LLMConfigurationStore.load(userDefaults: suite)
        XCTAssertEqual(settings.apiProtocol, .openai)
    }

    func test_saveAndLoad_roundTripsAnthropicProtocol() {
        let settings = LLMConfigurationStore.Settings(
            endpoint: "https://api.anthropic.com/v1/messages",
            model: "claude-sonnet-5",
            apiProtocol: .anthropic
        )
        LLMConfigurationStore.save(settings, userDefaults: suite)
        let loaded = LLMConfigurationStore.load(userDefaults: suite)
        XCTAssertEqual(loaded.apiProtocol, .anthropic)
        XCTAssertEqual(loaded.model, "claude-sonnet-5")
    }

    func test_makeService_anthropicProtocol_returnsAnthropicLLMService() throws {
        let settings = LLMConfigurationStore.Settings(
            endpoint: "https://api.anthropic.com/v1/messages",
            model: "claude-sonnet-5",
            apiProtocol: .anthropic
        )
        let service = try LLMConfigurationStore.makeService(settings: settings)
        XCTAssertTrue(service is AnthropicLLMService)
    }

    func test_makeService_openaiProtocol_returnsOpenAICompatibleLLMService() throws {
        let settings = LLMConfigurationStore.Settings(
            endpoint: "https://api.openai.com/v1/chat/completions",
            model: "gpt-4o-mini",
            apiProtocol: .openai
        )
        let service = try LLMConfigurationStore.makeService(settings: settings)
        XCTAssertTrue(service is OpenAICompatibleLLMService)
    }

    func test_makeService_notUsable_throwsNotConfigured() {
        let settings = LLMConfigurationStore.Settings(endpoint: "", model: "")
        XCTAssertThrowsError(try LLMConfigurationStore.makeService(settings: settings)) { error in
            XCTAssertEqual(error as? LLMServiceError, .notConfigured)
        }
    }

    func test_claudePresets_useAnthropicProtocolAndAreNotWebCapable() {
        let claudePresets = LLMConfigurationStore.presets.filter { $0.apiProtocol == .anthropic }
        XCTAssertEqual(claudePresets.count, 2)
        for preset in claudePresets {
            XCTAssertFalse(preset.webCapable)
            XCTAssertEqual(preset.endpoint, "https://api.anthropic.com/v1/messages")
        }
    }

    func test_nonAnthropicPresets_defaultToOpenAIProtocol() {
        let openAIPresets = LLMConfigurationStore.presets.filter { $0.apiProtocol == .openai }
        XCTAssertEqual(openAIPresets.count, LLMConfigurationStore.presets.count - 2)
    }
}
