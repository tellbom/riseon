import XCTest
@testable import RiseOn

/// Covers task.md S4.2's verification point: "初始化中途杀进程→重启→从中断步继续"
/// (kill the process mid-initialization -> restart -> resume from the
/// interrupted step). Simulated by hand-writing a "pre-crash" queue state to
/// `InitQueueStore`, then constructing a brand-new `InitializationQueue`
/// pointed at that same store — nothing is held in memory between "before
/// the crash" and "after the restart", only the file on disk.
final class InitializationQueueResumeTests: XCTestCase {

    private actor CallRecorder {
        private(set) var callsByCode: [String: [InitStep]] = [:]
        func record(code: String, step: InitStep) {
            callsByCode[code, default: []].append(step)
        }
    }

    private func makeTempStore() throws -> InitQueueStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InitQueueResumeTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return try InitQueueStore(directory: directory)
    }

    func test_resumesFromInterruptedStep_notFromTheStart() async throws {
        let store = try makeTempStore()

        // "Before the crash": steps A/B already succeeded, C was mid-flight
        // (`.running`) when the process died, D/E never started.
        let preCrashState: [String: [InitTask]] = [
            "600519": [
                InitTask(code: "600519", step: .fetchDailyBars, status: .succeeded),
                InitTask(code: "600519", step: .overlayRealtime, status: .succeeded),
                InitTask(code: "600519", step: .computeIndicators, retries: 1, status: .running),
                InitTask(code: "600519", step: .computeRuleScore, status: .pending),
                InitTask(code: "600519", step: .buildPack, status: .pending),
            ],
        ]
        try await store.save(preCrashState)

        // "After the restart": a brand-new queue instance, same store.
        let recorder = CallRecorder()
        let queue = InitializationQueue(store: store) { code, step in
            await recorder.record(code: code, step: step)
        }

        try await queue.restoreFromPersistedState()
        await queue.waitUntilIdle()

        let calls = await recorder.callsByCode["600519"]
        XCTAssertEqual(
            calls,
            [.computeIndicators, .computeRuleScore, .buildPack],
            "must resume at the interrupted step, not re-run fetchDailyBars/overlayRealtime"
        )

        let outcome = await queue.outcome(for: "600519")
        XCTAssertEqual(outcome, .succeeded)
    }

    func test_permanentlyFailedStock_isNotAutoResumedAfterRestart() async throws {
        let store = try makeTempStore()

        let preCrashState: [String: [InitTask]] = [
            "000001": [
                InitTask(code: "000001", step: .fetchDailyBars, status: .succeeded),
                InitTask(code: "000001", step: .overlayRealtime, retries: 3, status: .failed),
                InitTask(code: "000001", step: .computeIndicators, status: .pending),
                InitTask(code: "000001", step: .computeRuleScore, status: .pending),
                InitTask(code: "000001", step: .buildPack, status: .pending),
            ],
        ]
        try await store.save(preCrashState)

        let recorder = CallRecorder()
        let queue = InitializationQueue(store: store) { code, step in
            await recorder.record(code: code, step: step)
        }

        try await queue.restoreFromPersistedState()
        await queue.waitUntilIdle()

        let calls = await recorder.callsByCode["000001"]
        XCTAssertNil(calls, "a permanently-failed stock must stay stopped, not be auto-retried on restart")

        let outcome = await queue.outcome(for: "000001")
        XCTAssertEqual(outcome, .failed(.overlayRealtime))
    }

    func test_fullySucceededStock_isNotRerunAfterRestart() async throws {
        let store = try makeTempStore()

        let preCrashState: [String: [InitTask]] = [
            "300059": InitStep.allCases.map { InitTask(code: "300059", step: $0, status: .succeeded) },
        ]
        try await store.save(preCrashState)

        let recorder = CallRecorder()
        let queue = InitializationQueue(store: store) { code, step in
            await recorder.record(code: code, step: step)
        }

        try await queue.restoreFromPersistedState()
        await queue.waitUntilIdle()

        let calls = await recorder.callsByCode["300059"]
        XCTAssertNil(calls, "an already-fully-succeeded stock must not be re-run")

        let outcome = await queue.outcome(for: "300059")
        XCTAssertEqual(outcome, .succeeded)
    }

    func test_noStore_restoreIsANoOp() async throws {
        // A queue constructed without a store (e.g. previews/tests that
        // don't care about persistence) must tolerate `restoreFromPersistedState()`
        // being called anyway.
        let queue = InitializationQueue { _, _ in }
        try await queue.restoreFromPersistedState()
        await queue.waitUntilIdle()
    }
}
