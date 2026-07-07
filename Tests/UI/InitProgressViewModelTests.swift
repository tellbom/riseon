import XCTest
@testable import RiseOn

/// Covers the testable logic behind task.md S13.1's progress UI: the view
/// model correctly reflects `InitializationQueue` state as it changes, and
/// driving `retry()` through the view model resumes tracking correctly.
/// The actual on-screen rendering ("真机观测进度推进；单步失败可点重试恢复")
/// is a real-device verification task.md itself calls for — not something a
/// unit test can confirm — so this covers the state management the UI
/// would be driven by, using a real `InitializationQueue` (not a further
/// mock of it) so the integration is genuine.
@MainActor
final class InitProgressViewModelTests: XCTestCase {

    func test_observe_tracksProgressThroughToSuccess() async {
        let queue = InitializationQueue(configuration: .init(baseBackoffSeconds: 0.01)) { _, _ in
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms per step, something to observe mid-flight
        }
        let viewModel = InitProgressViewModel(code: "600519", queue: queue, pollIntervalNanoseconds: 5_000_000)

        await queue.enqueue("600519")
        await viewModel.observe() // should return once settled

        XCTAssertEqual(viewModel.outcome, .succeeded)
        XCTAssertEqual(viewModel.tasks.map(\.status), Array(repeating: InitTaskStatus.succeeded, count: 5))
        XCTAssertEqual(viewModel.tasks.map(\.step), InitStep.allCases)
    }

    func test_observe_settlesOnFailureWithoutHanging() async {
        let queue = InitializationQueue(
            configuration: .init(maxRetriesPerStep: 0, baseBackoffSeconds: 0.01)
        ) { _, step in
            if step == .computeIndicators {
                struct Boom: Error {}
                throw Boom()
            }
        }
        let viewModel = InitProgressViewModel(code: "600519", queue: queue, pollIntervalNanoseconds: 5_000_000)

        await queue.enqueue("600519")
        await viewModel.observe()

        XCTAssertEqual(viewModel.outcome, .failed(.computeIndicators))
        let failedTask = viewModel.tasks.first { $0.step == .computeIndicators }
        XCTAssertEqual(failedTask?.status, .failed)
    }

    func test_refreshSnapshot_reflectsCurrentStateWithoutWaitingForSettlement() async {
        let gate = Gate()
        let queue = InitializationQueue { _, step in
            if step == .fetchDailyBars {
                await gate.wait() // hold the first step open so we can observe mid-flight
            }
        }
        let viewModel = InitProgressViewModel(code: "600519", queue: queue)

        await queue.enqueue("600519")
        try? await Task.sleep(nanoseconds: 10_000_000) // let it actually start
        await viewModel.refreshSnapshot()

        XCTAssertNil(viewModel.outcome, "still mid-flight, must not report settled yet")
        XCTAssertFalse(viewModel.tasks.isEmpty)

        await gate.open()
        await queue.waitUntilIdle()
    }

    func test_retry_resumesTrackingAndEventuallySucceeds() async {
        let attempts = Counter()
        let queue = InitializationQueue(
            configuration: .init(maxRetriesPerStep: 0, baseBackoffSeconds: 0.01)
        ) { _, step in
            guard step == .buildPack else { return }
            let count = await attempts.increment()
            if count == 1 {
                struct Boom: Error {}
                throw Boom() // fail the first attempt at this step only
            }
        }
        let viewModel = InitProgressViewModel(code: "600519", queue: queue, pollIntervalNanoseconds: 5_000_000)

        await queue.enqueue("600519")
        await viewModel.observe()
        XCTAssertEqual(viewModel.outcome, .failed(.buildPack))

        await viewModel.retry()

        XCTAssertEqual(viewModel.outcome, .succeeded)
        XCTAssertFalse(viewModel.isRetrying, "must reset after retry settles")
    }

    func test_retry_isANoOpWhileAlreadyRetrying() async {
        let queue = InitializationQueue { _, _ in
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let viewModel = InitProgressViewModel(code: "600519", queue: queue, pollIntervalNanoseconds: 5_000_000)
        await queue.enqueue("600519")
        await viewModel.observe()
        XCTAssertEqual(viewModel.outcome, .succeeded)

        // Calling retry twice concurrently: the second call should just see
        // `isRetrying == true` and return immediately rather than double-driving `queue.retry`.
        async let first: Void = viewModel.retry()
        async let second: Void = viewModel.retry()
        _ = await (first, second)

        XCTAssertEqual(viewModel.outcome, .succeeded)
    }

    // MARK: - Test helpers

    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            isOpen = true
            let toResume = waiters
            waiters.removeAll()
            for continuation in toResume {
                continuation.resume()
            }
        }
    }

    private actor Counter {
        private var value = 0
        @discardableResult
        func increment() -> Int {
            value += 1
            return value
        }
    }
}
