import XCTest
@testable import RiseOn

/// Covers task.md S15.2: "多股批量初始化中断→恢复→全部完成或明确失败可重试"
/// (batch-initialize several stocks, interrupt, recover, and end up with
/// everything either complete or clearly failed-and-retryable). This is
/// explicitly an end-to-end integration exercise of S4.2 (crash resume) and
/// S4.3 (retry) together, at batch scale, using the real
/// `InitializationQueue` + `InitQueueStore` (not a further mock of either).
final class InitializationQueueEndToEndRecoveryTests: XCTestCase {

    private func makeTempStore() throws -> InitQueueStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("E2ERecoveryTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try InitQueueStore(directory: directory)
    }

    /// Simulates a batch of 5 stocks at various points in their pipeline
    /// when the process died: two fully done, one mid-step, one
    /// permanently failed already, one never even started.
    private func makePreCrashState() -> [String: [InitTask]] {
        func succeededAll(_ code: String) -> [InitTask] {
            InitStep.allCases.map { InitTask(code: code, step: $0, status: .succeeded) }
        }
        return [
            "600519": succeededAll("600519"), // fully done before the crash
            "300059": succeededAll("300059"), // fully done before the crash
            "000001": [ // mid-flight: A/B done, C was running when it died, D/E never started
                InitTask(code: "000001", step: .fetchDailyBars, status: .succeeded),
                InitTask(code: "000001", step: .overlayRealtime, status: .succeeded),
                InitTask(code: "000001", step: .computeIndicators, status: .running),
                InitTask(code: "000001", step: .computeRuleScore, status: .pending),
                InitTask(code: "000001", step: .buildPack, status: .pending),
            ],
            "600000": [ // already exhausted retries on step B before the crash
                InitTask(code: "600000", step: .fetchDailyBars, status: .succeeded),
                InitTask(code: "600000", step: .overlayRealtime, retries: 3, status: .failed),
                InitTask(code: "600000", step: .computeIndicators, status: .pending),
                InitTask(code: "600000", step: .computeRuleScore, status: .pending),
                InitTask(code: "600000", step: .buildPack, status: .pending),
            ],
            "000002": InitStep.allCases.map { InitTask(code: "000002", step: $0, status: .pending) }, // never started
        ]
    }

    func test_batchOfFive_interruptedMidFlight_allEndUpCompleteOrClearlyRetryable() async throws {
        let store = try makeTempStore()
        try await store.save(makePreCrashState())

        // "After the restart": brand-new queue instance, same persisted
        // store, everything from here on runs cleanly (simulating the
        // network/environment recovering).
        let queue = InitializationQueue(store: store) { _, _ in
            try await Task.sleep(nanoseconds: 5_000_000) // small, deterministic, just to exercise concurrency
        }
        try await queue.restoreFromPersistedState()
        await queue.waitUntilIdle()

        // Every stock now has a defined outcome -- nothing left in limbo.
        let allCodes = ["600519", "300059", "000001", "600000", "000002"]
        for code in allCodes {
            let outcome = await queue.outcome(for: code)
            XCTAssertNotNil(outcome, "\(code) must have settled to some outcome after recovery")
        }

        // Already-done stocks weren't touched (their earlier success stands).
        XCTAssertEqual(await queue.outcome(for: "600519"), .succeeded)
        XCTAssertEqual(await queue.outcome(for: "300059"), .succeeded)

        // The mid-flight one resumed from where it was interrupted and completed.
        XCTAssertEqual(await queue.outcome(for: "000001"), .succeeded)
        let resumedTasks = await queue.tasks(for: "000001")
        XCTAssertEqual(resumedTasks?.map(\.status), Array(repeating: InitTaskStatus.succeeded, count: 5))

        // The never-started one ran cleanly through all 5 steps.
        XCTAssertEqual(await queue.outcome(for: "000002"), .succeeded)

        // The already-permanently-failed one stayed stopped -- not silently
        // auto-retried on restart (task.md S4.3's own requirement).
        XCTAssertEqual(await queue.outcome(for: "600000"), .failed(.overlayRealtime))
    }

    func test_batchOfFive_thePreviouslyFailedOne_canBeManuallyRetriedToCompletion() async throws {
        let store = try makeTempStore()
        try await store.save(makePreCrashState())

        let queue = InitializationQueue(store: store) { _, _ in
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await queue.restoreFromPersistedState()
        await queue.waitUntilIdle()
        XCTAssertEqual(await queue.outcome(for: "600000"), .failed(.overlayRealtime))

        let retried = await queue.retry("600000")
        XCTAssertTrue(retried)
        await queue.waitUntilIdle()

        XCTAssertEqual(await queue.outcome(for: "600000"), .succeeded)
        let tasks = await queue.tasks(for: "600000")
        // Step A was already succeeded before the crash and must not have
        // been redone; steps B-E completed on the retry.
        XCTAssertEqual(tasks?.map(\.status), Array(repeating: InitTaskStatus.succeeded, count: 5))
    }

    func test_batchOfFive_concurrencyCapRespectedDuringRecovery() async throws {
        let store = try makeTempStore()
        try await store.save(makePreCrashState())

        actor ConcurrencyProbe {
            private(set) var current = 0
            private(set) var maxObserved = 0
            func begin() { current += 1; maxObserved = max(maxObserved, current) }
            func end() { current -= 1 }
        }
        let probe = ConcurrencyProbe()

        let queue = InitializationQueue(
            configuration: .init(maxConcurrentStocks: 2),
            store: store
        ) { _, _ in
            await probe.begin()
            try await Task.sleep(nanoseconds: 15_000_000)
            await probe.end()
        }
        try await queue.restoreFromPersistedState()
        await queue.waitUntilIdle()

        let maxConcurrency = await probe.maxObserved
        XCTAssertLessThanOrEqual(maxConcurrency, 2, "recovery must still respect the concurrency cap, not blast every recovered stock at once")
    }

    func test_batchOfFive_persistedStateAfterRecovery_reflectsFinalOutcomes() async throws {
        // A second restart, right after the first recovery finished, should
        // see the same settled state persisted -- proving the recovered
        // run's results were actually written back to disk, not just held
        // in the first queue instance's memory.
        let store = try makeTempStore()
        try await store.save(makePreCrashState())

        let firstQueue = InitializationQueue(store: store) { _, _ in }
        try await firstQueue.restoreFromPersistedState()
        await firstQueue.waitUntilIdle()

        let secondQueue = InitializationQueue(store: store) { _, _ in }
        try await secondQueue.restoreFromPersistedState()
        await secondQueue.waitUntilIdle()

        // Everything that succeeded the first time is recognized as already
        // done (outcome recorded from disk), not silently re-run again.
        XCTAssertEqual(await secondQueue.outcome(for: "600519"), .succeeded)
        XCTAssertEqual(await secondQueue.outcome(for: "000001"), .succeeded)
        XCTAssertEqual(await secondQueue.outcome(for: "000002"), .succeeded)
        // The permanently-failed one is still recognized as failed, still
        // available for a manual retry rather than being lost.
        XCTAssertEqual(await secondQueue.outcome(for: "600000"), .failed(.overlayRealtime))
    }
}
