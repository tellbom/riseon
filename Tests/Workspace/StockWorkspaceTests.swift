import XCTest
@testable import RiseOn

/// Covers task.md S2.1's verification point: "状态流转单测覆盖所有合法转移"
/// (unit tests cover every legal transition) — plus a sample of illegal ones
/// and the `failed(step)` associated-value behavior.
final class StockWorkspaceTests: XCTestCase {

    private let allStates: [WorkspaceState] = [
        .uninitialized,
        .initializing,
        .ready,
        .partial,
        .stale,
        .failed(.fetchDailyBars),
    ]

    private let legalPairs: [(WorkspaceState, WorkspaceState)] = [
        (.uninitialized, .initializing),
        (.initializing, .ready),
        (.initializing, .partial),
        (.initializing, .failed(.fetchDailyBars)),
        (.initializing, .failed(.overlayRealtime)),
        (.initializing, .failed(.computeIndicators)),
        (.initializing, .failed(.computeRuleScore)),
        (.initializing, .failed(.buildPack)),
        (.ready, .stale),
        (.partial, .stale),
        (.ready, .initializing),
        (.partial, .initializing),
        (.stale, .initializing),
        (.failed(.fetchDailyBars), .initializing),
        (.failed(.buildPack), .initializing),
    ]

    func test_allDeclaredLegalPairs_areAllowed() {
        for (from, to) in legalPairs {
            XCTAssertTrue(
                from.canTransition(to: to),
                "expected \(from) -> \(to) to be legal"
            )
        }
    }

    func test_allDeclaredLegalPairs_actuallyMutateWorkspaceState() throws {
        for (from, to) in legalPairs {
            var workspace = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh")
            try forceState(&workspace, to: from)
            try workspace.transition(to: to)
            XCTAssertEqual(workspace.state, to)
        }
    }

    func test_exhaustivePairs_matchExpectedTruthTable() {
        func isDeclaredLegal(_ from: WorkspaceState, _ to: WorkspaceState) -> Bool {
            legalPairs.contains { $0.0 == from && $0.1 == to }
        }

        for from in allStates {
            for to in allStates {
                let expected = isDeclaredLegal(from, to)
                XCTAssertEqual(
                    from.canTransition(to: to),
                    expected,
                    "\(from) -> \(to) expected legal=\(expected)"
                )
            }
        }
    }

    func test_illegalTransition_throwsWithFromAndTo() throws {
        var workspace = StockWorkspace(code: "000001", name: "平安银行", market: "sz")
        // uninitialized -> ready is not in the legal graph.
        XCTAssertThrowsError(try workspace.transition(to: .ready)) { error in
            guard case let WorkspaceTransitionError.illegal(from, to) = error else {
                return XCTFail("expected .illegal, got \(error)")
            }
            XCTAssertEqual(from, .uninitialized)
            XCTAssertEqual(to, .ready)
        }
        // State must be unchanged after a rejected transition.
        XCTAssertEqual(workspace.state, .uninitialized)
    }

    func test_illegalTransition_uninitializedCannotGoDirectlyToStale() {
        XCTAssertFalse(WorkspaceState.uninitialized.canTransition(to: .stale))
    }

    func test_illegalTransition_readyCannotGoDirectlyToPartial() {
        XCTAssertFalse(WorkspaceState.ready.canTransition(to: .partial))
    }

    func test_illegalTransition_failedCannotGoDirectlyToReady() {
        XCTAssertFalse(WorkspaceState.failed(.computeRuleScore).canTransition(to: .ready))
    }

    func test_newWorkspace_startsUninitialized() {
        let workspace = StockWorkspace(code: "300059", name: "东方财富", market: "sz")
        XCTAssertEqual(workspace.state, .uninitialized)
        XCTAssertNil(workspace.contextPack)
        XCTAssertNil(workspace.ruleScore)
        XCTAssertEqual(workspace.chatSession.code, "300059")
        XCTAssertEqual(workspace.chatSession.messages, [])
    }

    /// Drives a fresh (`.uninitialized`) workspace to `target` via legal hops only,
    /// so per-test setup doesn't rely on ever mutating `state` illegally.
    private func forceState(_ workspace: inout StockWorkspace, to target: WorkspaceState) throws {
        guard target != .uninitialized else { return }
        try workspace.transition(to: .initializing)
        guard target != .initializing else { return }

        switch target {
        case .ready:
            try workspace.transition(to: .ready)
        case .partial:
            try workspace.transition(to: .partial)
        case .stale:
            // stale is only reachable from ready/partial; go via ready.
            try workspace.transition(to: .ready)
            try workspace.transition(to: .stale)
        case .failed(let step):
            try workspace.transition(to: .failed(step))
        case .uninitialized, .initializing:
            break
        }
    }
}

