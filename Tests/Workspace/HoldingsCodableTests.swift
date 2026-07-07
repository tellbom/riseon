import XCTest
@testable import RiseOn

/// Covers task.md S2.2's verification point: "Codable 往返序列化单测通过"
/// (Codable round-trip tests pass) for `ContextPack`, `RuleScore`,
/// `ChatThread`, `WorkspaceMeta`, and the `StockWorkspace` that holds them.
final class HoldingsCodableTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func test_workspaceMeta_roundTrips() throws {
        let original = WorkspaceMeta(
            snapshotDate: Date(timeIntervalSince1970: 1_750_000_000),
            source: "tencent",
            quality: "good"
        )
        let decoded = try roundTrip(original)
        XCTAssertEqual(decoded, original)
    }

    func test_workspaceMeta_roundTrips_withNilFields() throws {
        let original = WorkspaceMeta(snapshotDate: nil, source: "", quality: nil)
        let decoded = try roundTrip(original)
        XCTAssertEqual(decoded, original)
    }

    func test_contextPack_roundTrips() throws {
        let original = ContextPack(
            subject: ContextPackSubject(code: "600519", stockName: "贵州茅台", market: "sh"),
            packVersion: "1.0",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let decoded = try roundTrip(original)
        XCTAssertEqual(decoded, original)
    }

    func test_ruleScore_roundTrips() throws {
        let original = RuleScore(
            code: "300059",
            signalScore: 72,
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let decoded = try roundTrip(original)
        XCTAssertEqual(decoded, original)
    }

    func test_chatThread_roundTrips_withMessages() throws {
        let original = ChatThread(
            code: "000001",
            messages: [
                ChatMessage(role: .user, content: "现在能买吗？", createdAt: Date(timeIntervalSince1970: 1_750_000_000)),
                ChatMessage(role: .assistant, content: "仅供参考，不构成投资建议。", createdAt: Date(timeIntervalSince1970: 1_750_000_100)),
            ]
        )
        let decoded = try roundTrip(original)
        XCTAssertEqual(decoded, original)
    }

    func test_chatThread_roundTrips_empty() throws {
        let original = ChatThread(code: "000001", messages: [])
        let decoded = try roundTrip(original)
        XCTAssertEqual(decoded, original)
    }

    func test_stockWorkspace_roundTrips_uninitialized() throws {
        let original = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh")
        let decoded = try roundTrip(original)
        XCTAssertEqual(decoded, original)
    }

    func test_stockWorkspace_roundTrips_withHoldingsPopulated() throws {
        var workspace = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh")
        workspace.contextPack = ContextPack(
            subject: ContextPackSubject(code: "600519", stockName: "贵州茅台", market: "sh")
        )
        workspace.ruleScore = RuleScore(code: "600519", signalScore: 61)
        try workspace.appendChatMessage(
            ChatMessage(role: .user, content: "帮我看看走势", createdAt: Date(timeIntervalSince1970: 1_750_000_000))
        )
        workspace.meta = WorkspaceMeta(snapshotDate: Date(timeIntervalSince1970: 1_750_000_000), source: "tencent", quality: "usable")
        try workspace.transition(to: .initializing)
        try workspace.transition(to: .ready)

        let decoded = try roundTrip(workspace)
        XCTAssertEqual(decoded, workspace)
        XCTAssertEqual(decoded.state, .ready)
    }

    func test_stockWorkspace_roundTrips_failedState() throws {
        var workspace = StockWorkspace(code: "300059", name: "东方财富", market: "sz")
        try workspace.transition(to: .initializing)
        try workspace.transition(to: .failed(.overlayRealtime))

        let decoded = try roundTrip(workspace)
        XCTAssertEqual(decoded.state, .failed(.overlayRealtime))
    }

    // MARK: - Helper

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try encoder.encode(value)
        return try decoder.decode(T.self, from: data)
    }
}
