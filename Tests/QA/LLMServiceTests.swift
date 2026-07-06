import XCTest
@testable import RiseOn

/// Covers task.md S10.1 (protocol accepts a mock) and the pure-logic half of
/// S10.2 (status-code -> error mapping, response parsing).
///
/// NOT covered here (consistent with how `TencentDailyProvider`'s retry
/// logic was left untested in S5): the actual network call itself. This
/// codebase doesn't inject a mockable `URLSession`/`URLProtocol` anywhere
/// else either, so `OpenAICompatibleLLMService.generate` end-to-end against
/// a live or stubbed network isn't unit tested — task.md S10.2's "真机一次
/// 成功问答" verification point is explicitly a real-device check, not
/// something to fake here.
final class LLMServiceTests: XCTestCase {

    // MARK: - S10.1: protocol substitutability

    private struct MockLLMService: LLMService {
        var response: Result<String, LLMServiceError>

        func generate(system: String, user: String) async throws -> String {
            switch response {
            case .success(let text): return text
            case .failure(let error): throw error
            }
        }
    }

    func test_protocolAcceptsAMockConformer() async throws {
        let mock: LLMService = MockLLMService(response: .success("mock answer"))
        let result = try await mock.generate(system: "sys", user: "usr")
        XCTAssertEqual(result, "mock answer")
    }

    func test_mockConformer_canSimulateFailure() async {
        let mock: LLMService = MockLLMService(response: .failure(LLMServiceError.notConfigured))
        do {
            _ = try await mock.generate(system: "sys", user: "usr")
            XCTFail("expected an error to be thrown")
        } catch let error as LLMServiceError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("expected LLMServiceError, got \(error)")
        }
    }

    /// A function that only cares about "some `LLMService`" -- proving the
    /// protocol is genuinely usable as an injectable dependency, not just
    /// theoretically conformable.
    private func askOnce(_ service: LLMService, question: String) async throws -> String {
        try await service.generate(system: "answer briefly", user: question)
    }

    func test_genericCallSite_worksWithMockWithoutKnowingConcreteType() async throws {
        let answer = try await askOnce(MockLLMService(response: .success("42")), question: "what is the answer?")
        XCTAssertEqual(answer, "42")
    }

    // MARK: - S10.2: status-code -> error mapping (pure function)

    func test_statusCode2xx_mapsToNoError() {
        for code in [200, 201, 204, 299] {
            XCTAssertNil(OpenAICompatibleLLMService.error(forStatusCode: code, body: Data()))
        }
    }

    func test_statusCode401And403_mapToUnauthorized() {
        XCTAssertEqual(OpenAICompatibleLLMService.error(forStatusCode: 401, body: Data()), .unauthorized)
        XCTAssertEqual(OpenAICompatibleLLMService.error(forStatusCode: 403, body: Data()), .unauthorized)
    }

    func test_statusCode429_mapsToRateLimited() {
        XCTAssertEqual(OpenAICompatibleLLMService.error(forStatusCode: 429, body: Data()), .rateLimited)
    }

    func test_statusCode5xx_mapsToServerErrorWithBodyMessage() {
        let body = "internal error detail".data(using: .utf8)!
        XCTAssertEqual(
            OpenAICompatibleLLMService.error(forStatusCode: 500, body: body),
            .serverError(statusCode: 500, message: "internal error detail")
        )
        XCTAssertEqual(
            OpenAICompatibleLLMService.error(forStatusCode: 503, body: Data()),
            .serverError(statusCode: 503, message: "")
        )
    }

    func test_otherStatusCodes_mapToServerErrorAsFallback() {
        // e.g. 400 bad request -- not explicitly named in task.md's three
        // examples (超时/鉴权/空输出), so it falls back to the generic
        // serverError bucket rather than being silently swallowed.
        XCTAssertEqual(
            OpenAICompatibleLLMService.error(forStatusCode: 400, body: Data()),
            .serverError(statusCode: 400, message: "")
        )
    }

    // MARK: - S10.2: response parsing (pure function)

    func test_extractContent_validResponse_returnsText() throws {
        let json = #"{"choices":[{"message":{"role":"assistant","content":"这是回答"}}]}"#
        let content = try OpenAICompatibleLLMService.extractContent(from: json.data(using: .utf8)!)
        XCTAssertEqual(content, "这是回答")
    }

    func test_extractContent_malformedJSON_throwsInvalidResponse() {
        let data = "not json at all".data(using: .utf8)!
        XCTAssertThrowsError(try OpenAICompatibleLLMService.extractContent(from: data)) { error in
            guard case LLMServiceError.invalidResponse = error else {
                return XCTFail("expected .invalidResponse, got \(error)")
            }
        }
    }

    func test_extractContent_missingChoicesKey_throwsInvalidResponse() {
        let json = #"{"unexpected": "shape"}"#
        XCTAssertThrowsError(try OpenAICompatibleLLMService.extractContent(from: json.data(using: .utf8)!)) { error in
            guard case LLMServiceError.invalidResponse = error else {
                return XCTFail("expected .invalidResponse, got \(error)")
            }
        }
    }

    func test_extractContent_emptyChoicesArray_throwsInvalidResponse() {
        let json = #"{"choices": []}"#
        XCTAssertThrowsError(try OpenAICompatibleLLMService.extractContent(from: json.data(using: .utf8)!)) { error in
            guard case LLMServiceError.invalidResponse = error else {
                return XCTFail("expected .invalidResponse, got \(error)")
            }
        }
    }

    func test_extractContent_emptyStringContent_throwsEmptyOutput() {
        let json = #"{"choices":[{"message":{"content":""}}]}"#
        XCTAssertThrowsError(try OpenAICompatibleLLMService.extractContent(from: json.data(using: .utf8)!)) { error in
            guard case LLMServiceError.emptyOutput = error else {
                return XCTFail("expected .emptyOutput, got \(error)")
            }
        }
    }

    // MARK: - LocalizedError messages exist and are non-empty (surfaced in UI)

    func test_everyError_hasANonEmptyLocalizedDescription() {
        let errors: [LLMServiceError] = [
            .notConfigured, .unauthorized, .rateLimited, .timeout,
            .network("dns failure"), .serverError(statusCode: 500, message: nil),
            .invalidResponse("bad shape"), .emptyOutput, .unknown("mystery"),
        ]
        for error in errors {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty, "\(error) needs a user-facing message")
        }
    }
}
