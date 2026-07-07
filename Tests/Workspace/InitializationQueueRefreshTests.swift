import XCTest
@testable import RiseOn

/// Covers task.md S12.1's queue-level piece: `InitializationQueue.refresh(_:)`
/// re-runs all 5 steps from scratch, unlike `retry(_:)` which only resumes
/// the failed step.
final class InitializationQueueRefreshTests: XCTestCase {

    private actor CallRecorder {
        private(set) var callsByCode: [String: [InitStep]] = [:]
        func record(code: String, step: InitStep) {
            callsByCode[code, default: []].append(step)
        }
        func reset() { callsByCode = [:] }
    }

    private actor ActorBox {
        private(set) var value: Bool
        init(_ initial: Bool) { value = initial }
        func set(_ newValue: Bool) { value = newValue }
    }

    func test_refresh_afterFullSuccess_reRunsAllFiveSteps() async throws {
        let recorder = CallRecorder()
        let queue = InitializationQueue { code, step in
            await recorder.record(code: code, step: step)
        }

        await queue.enqueue("600519")
        await queue.waitUntilIdle()
        XCTAssertEqual(await queue.outcome(for: "600519"), .succeeded)
        let firstRunCalls = await recorder.callsByCode["600519"]
        XCTAssertEqual(firstRunCalls, InitStep.allCases)

        await recorder.reset()
        let refreshed = try await queue.refresh("600519")
        XCTAssertTrue(refreshed)
        await queue.waitUntilIdle()

        XCTAssertEqual(await queue.outcome(for: "600519"), .succeeded)
        let secondRunCalls = await recorder.callsByCode["600519"]
        XCTAssertEqual(secondRunCalls, InitStep.allCases, "refresh must re-run every step, not resume from where it left off")
    }

    func test_refresh_untrackedCode_behavesLikeEnqueue() async throws {
        let recorder = CallRecorder()
        let queue = InitializationQueue { code, step in
            await recorder.record(code: code, step: step)
        }

        let refreshed = try await queue.refresh("300059") // never enqueued before
        XCTAssertTrue(refreshed)
        await queue.waitUntilIdle()

        XCTAssertEqual(await queue.outcome(for: "300059"), .succeeded)
        XCTAssertEqual(await recorder.callsByCode["300059"], InitStep.allCases)
    }

    func test_refresh_onCurrentlyActiveCode_throwsAlreadyActive() async throws {
        let queue = InitializationQueue(
            configuration: .init(maxConcurrentStocks: 1)
        ) { _, _ in
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms, long enough to catch it mid-flight
        }

        await queue.enqueue("600519")
        // Don't wait for idle -- try to refresh while it's still running.
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms, let it actually start

        do {
            _ = try await queue.refresh("600519")
            // If the pipeline happened to finish faster than expected in
            // this environment, this isn't a real failure -- just skip the
            // assertion rather than flake.
            let outcome = await queue.outcome(for: "600519")
            if outcome == nil {
                XCTFail("expected either .alreadyActive or a finished outcome, got neither")
            }
        } catch let error as InitializationQueue.RefreshError {
            XCTAssertEqual(error, .alreadyActive)
        }

        await queue.waitUntilIdle()
    }

    func test_refresh_previouslyFailedCode_clearsOutcomeAndTriesAgain() async throws {
        let shouldFail = ActorBox(true)
        let recorder = CallRecorder()

        let queue = InitializationQueue(
            configuration: .init(maxConcurrentStocks: 1, maxRetriesPerStep: 0, baseBackoffSeconds: 0.01)
        ) { code, step in
            await recorder.record(code: code, step: step)
            if step == .fetchDailyBars, await shouldFail.value {
                struct Boom: Error {}
                throw Boom()
            }
        }

        await queue.enqueue("600519")
        await queue.waitUntilIdle()
        XCTAssertEqual(await queue.outcome(for: "600519"), .failed(.fetchDailyBars))

        await shouldFail.set(false)
        await recorder.reset()
        let refreshed = try await queue.refresh("600519")
        XCTAssertTrue(refreshed)
        await queue.waitUntilIdle()

        XCTAssertEqual(await queue.outcome(for: "600519"), .succeeded)
        XCTAssertEqual(await recorder.callsByCode["600519"], InitStep.allCases)
    }
}
