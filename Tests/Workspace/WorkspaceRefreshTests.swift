import XCTest
@testable import RiseOn

/// Covers task.md S12.1's verification point: "刷新后数值与快照时间更新"
/// (after refresh, values and snapshot time are updated).
final class WorkspaceRefreshTests: XCTestCase {

    private func makePack(level: String) -> ContextPack {
        ContextPack(
            subject: ContextPackSubject(code: "600519", stockName: "贵州茅台", market: "sh"),
            dataQuality: DataQuality(overallScore: 80, level: level)
        )
    }

    private func makeInitializingWorkspace() throws -> StockWorkspace {
        var workspace = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh")
        try workspace.transition(to: .initializing)
        return workspace
    }

    func test_applyRefreshedPack_goodLevel_transitionsToReady() throws {
        var workspace = try makeInitializingWorkspace()
        let snapshotDate = Date(timeIntervalSince1970: 1_750_000_000)

        try workspace.applyRefreshedPack(makePack(level: "good"), ruleScore: RuleScore(code: "600519", signalScore: 80), snapshotDate: snapshotDate, source: "tencent")

        XCTAssertEqual(workspace.state, .ready)
    }

    func test_applyRefreshedPack_usableLevel_transitionsToReady() throws {
        var workspace = try makeInitializingWorkspace()
        try workspace.applyRefreshedPack(makePack(level: "usable"), ruleScore: nil, snapshotDate: Date(), source: "tencent")
        XCTAssertEqual(workspace.state, .ready)
    }

    func test_applyRefreshedPack_limitedLevel_transitionsToPartial() throws {
        var workspace = try makeInitializingWorkspace()
        try workspace.applyRefreshedPack(makePack(level: "limited"), ruleScore: nil, snapshotDate: Date(), source: "tencent")
        XCTAssertEqual(workspace.state, .partial)
    }

    func test_applyRefreshedPack_poorLevel_transitionsToPartial() throws {
        var workspace = try makeInitializingWorkspace()
        try workspace.applyRefreshedPack(makePack(level: "poor"), ruleScore: nil, snapshotDate: Date(), source: "tencent")
        XCTAssertEqual(workspace.state, .partial)
    }

    func test_applyRefreshedPack_updatesSnapshotDateSourceAndQuality() throws {
        var workspace = try makeInitializingWorkspace()
        let snapshotDate = Date(timeIntervalSince1970: 1_750_000_000)

        try workspace.applyRefreshedPack(makePack(level: "good"), ruleScore: nil, snapshotDate: snapshotDate, source: "tencent")

        XCTAssertEqual(workspace.meta.snapshotDate, snapshotDate)
        XCTAssertEqual(workspace.meta.source, "tencent")
        XCTAssertEqual(workspace.meta.quality, "good")
    }

    func test_applyRefreshedPack_updatesContextPackAndRuleScore() throws {
        var workspace = try makeInitializingWorkspace()
        let pack = makePack(level: "good")
        let ruleScore = RuleScore(code: "600519", signalScore: 71)

        try workspace.applyRefreshedPack(pack, ruleScore: ruleScore, snapshotDate: Date(), source: "tencent")

        XCTAssertEqual(workspace.contextPack, pack)
        XCTAssertEqual(workspace.ruleScore, ruleScore)
    }

    func test_applyRefreshedPack_replacesStaleData_onASecondRefresh() throws {
        var workspace = try makeInitializingWorkspace()
        try workspace.applyRefreshedPack(makePack(level: "poor"), ruleScore: RuleScore(code: "600519", signalScore: 10), snapshotDate: Date(timeIntervalSince1970: 1), source: "tencent")
        XCTAssertEqual(workspace.state, .partial)

        // Simulate a later, better refresh replacing the earlier one.
        try workspace.transition(to: .initializing)
        let newSnapshot = Date(timeIntervalSince1970: 2_000_000_000)
        try workspace.applyRefreshedPack(makePack(level: "good"), ruleScore: RuleScore(code: "600519", signalScore: 90), snapshotDate: newSnapshot, source: "tencent")

        XCTAssertEqual(workspace.state, .ready)
        XCTAssertEqual(workspace.meta.snapshotDate, newSnapshot)
        XCTAssertEqual(workspace.ruleScore?.signalScore, 90)
    }

    func test_applyRefreshedPack_fromNonInitializingState_throwsIllegalTransition() {
        var workspace = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh") // still .uninitialized

        XCTAssertThrowsError(
            try workspace.applyRefreshedPack(makePack(level: "good"), ruleScore: nil, snapshotDate: Date(), source: "tencent")
        ) { error in
            guard case WorkspaceTransitionError.illegal(let from, let to) = error else {
                return XCTFail("expected .illegal, got \(error)")
            }
            XCTAssertEqual(from, .uninitialized)
            XCTAssertEqual(to, .ready)
        }
    }
}
