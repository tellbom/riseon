import XCTest
@testable import RiseOn

/// Covers task.md S4.3's verification point: "模拟网络失败→重试→最终可手动重试成功"
/// (simulate a network failure -> automatic backoff retries happen and get
/// exhausted -> a manual retry eventually succeeds).
final class InitializationQueueRetryTests: XCTestCase {

    /// Fails every call up to and including `failUntilAttempt`, then
    /// succeeds forever after — simulating a flaky network that eventually
    /// recovers once the person keeps hitting "retry".
    private actor FailThenSucceedExecutor {
        private var attemptsByStep: [InitStep: Int] = [:]
        private let failUntilAttempt: Int

        init(failUntilAttempt: Int) {
            self.failUntilAttempt = failUntilAttempt
        }

        struct SimulatedNetworkFailure: Error {}

        func attempt(step: InitStep) throws {
            let count = (attemptsByStep[step] ?? 0) + 1
            attemptsByStep[step] = count
            if count <= failUntilAttempt {
                throw SimulatedNetworkFailure()
            }
        }

        func attemptCount(for step: InitStep) -> Int {
            attemptsByStep[step] ?? 0
        }
    }

    /// Holds a mutable flag that a `@Sendable` step-executor closure can flip
    /// mid-test — an `actor` rather than a captured `var`, since a plain `var`
    /// mutated from inside a `@Sendable` closure isn't safe/legal.
    private actor FlagBox {
        private(set) var value: Bool
        init(_ initial: Bool) { value = initial }
        func set(_ newValue: Bool) { value = newValue }
    }

    private actor StepCallRecorder {
        private(set) var calls: [InitStep] = []
        func record(_ step: InitStep) { calls.append(step) }
        func reset() { calls = [] }
    }

    func test_exhaustsAutomaticRetries_thenManualRetryEventuallySucceeds() async throws {
        // Fails 5 times total — comfortably more than maxRetriesPerStep(2),
        // so the queue must give up on its own before ever succeeding.
        let executor = FailThenSucceedExecutor(failUntilAttempt: 5)

        let queue = InitializationQueue(
            configuration: .init(maxConcurrentStocks: 1, maxRetriesPerStep: 2, baseBackoffSeconds: 0.01)
        ) { _, step in
            guard step == .overlayRealtime else { return } // only this step is flaky
            try await executor.attempt(step: step)
        }

        await queue.enqueue("600519")
        await queue.waitUntilIdle()

        XCTAssertEqual(await queue.outcome(for: "600519"), .failed(.overlayRealtime))
        // 1 initial attempt + 2 retries = 3 attempts, all failed.
        XCTAssertEqual(await executor.attemptCount(for: .overlayRealtime), 3)

        var outcome: InitializationQueue.Outcome?
        for _ in 0..<5 {
            outcome = await queue.outcome(for: "600519")
            if outcome == .succeeded { break }
            let retried = await queue.retry("600519")
            XCTAssertTrue(retried)
            await queue.waitUntilIdle()
        }
        outcome = await queue.outcome(for: "600519")

        XCTAssertEqual(outcome, .succeeded, "manual retry must eventually succeed once the failure clears")

        let tasks = await queue.tasks(for: "600519")
        XCTAssertEqual(tasks?.map(\.status), Array(repeating: InitTaskStatus.succeeded, count: 5))
    }

    func test_retry_onUnknownOrNonFailedCode_returnsFalse() async throws {
        let queue = InitializationQueue { _, _ in }

        XCTAssertFalse(await queue.retry("does_not_exist"))

        await queue.enqueue("600519")
        await queue.waitUntilIdle() // succeeds immediately (no-op executor)
        XCTAssertFalse(await queue.retry("600519"), "an already-succeeded stock has no failure to retry")
    }

    func test_retry_resumesFromTheFailedStepOnly() async throws {
        let recorder = StepCallRecorder()
        let shouldFail = FlagBox(true)

        let queue = InitializationQueue(
            configuration: .init(maxConcurrentStocks: 1, maxRetriesPerStep: 0, baseBackoffSeconds: 0.01)
        ) { _, step in
            await recorder.record(step)
            if step == .computeIndicators, await shouldFail.value {
                struct Boom: Error {}
                throw Boom()
            }
        }

        await queue.enqueue("600519")
        await queue.waitUntilIdle()
        XCTAssertEqual(await queue.outcome(for: "600519"), .failed(.computeIndicators))

        await shouldFail.set(false)
        await recorder.reset()

        let retried = await queue.retry("600519")
        XCTAssertTrue(retried)
        await queue.waitUntilIdle()

        XCTAssertEqual(await queue.outcome(for: "600519"), .succeeded)
        XCTAssertEqual(
            await recorder.calls,
            [.computeIndicators, .computeRuleScore, .buildPack],
            "retry must resume at computeIndicators, not re-run fetchDailyBars/overlayRealtime"
        )
    }
}
