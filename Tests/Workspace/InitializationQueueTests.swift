import XCTest
@testable import RiseOn

/// Covers task.md S4.1's verification point: "批量入队 5 只，观测并发不超上限、按序完成"
/// (batch-enqueue 5 stocks, observe concurrency never exceeds the cap, and
/// each stock's own steps complete in A-E order).
final class InitializationQueueTests: XCTestCase {

    /// Test-only helper: tracks how many step executions are in flight at
    /// once (for the concurrency-cap assertion) and the exact call order per
    /// stock (for the "steps run in order" assertion). An `actor` because the
    /// mock `StepExecutor` runs concurrently across stocks.
    private actor CallRecorder {
        private(set) var currentConcurrency = 0
        private(set) var maxObservedConcurrency = 0
        private(set) var callsByCode: [String: [InitStep]] = [:]

        func begin(code: String, step: InitStep) {
            currentConcurrency += 1
            maxObservedConcurrency = max(maxObservedConcurrency, currentConcurrency)
            callsByCode[code, default: []].append(step)
        }

        func end() {
            currentConcurrency -= 1
        }
    }

    func test_batchEnqueueFive_respectsConcurrencyCapAndPerStockOrder() async throws {
        let recorder = CallRecorder()
        let queue = InitializationQueue(
            configuration: .init(maxConcurrentStocks: 2, maxRetriesPerStep: 1, baseBackoffSeconds: 0.01)
        ) { code, step in
            await recorder.begin(code: code, step: step)
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms, long enough for overlap
            await recorder.end()
        }

        let codes = ["600519", "000001", "300059", "600000", "000002"]
        await queue.enqueue(codes)
        await queue.waitUntilIdle()

        // Timing-sensitive but not flaky in practice: 5 stocks, cap 2, 20ms
        // per step gives ample room to observe real overlap.
        let maxConcurrency = await recorder.maxObservedConcurrency
        XCTAssertLessThanOrEqual(maxConcurrency, 2, "must never exceed maxConcurrentStocks")
        XCTAssertGreaterThan(maxConcurrency, 1, "sanity check: stocks should have actually overlapped")

        for code in codes {
            let outcome = await queue.outcome(for: code)
            XCTAssertEqual(outcome, .succeeded, "\(code) should have completed successfully")

            let calls = await recorder.callsByCode[code]
            XCTAssertEqual(calls, InitStep.allCases, "\(code)'s steps must run in A-E order")
        }
    }

    func test_enqueueSameCodeTwice_isANoOp() async throws {
        let recorder = CallRecorder()
        let queue = InitializationQueue { code, step in
            await recorder.begin(code: code, step: step)
            await recorder.end()
        }

        await queue.enqueue("600519")
        await queue.enqueue("600519") // must not start a second pipeline
        await queue.waitUntilIdle()

        let calls = await recorder.callsByCode["600519"]
        XCTAssertEqual(calls, InitStep.allCases)
    }

    func test_defaultConfiguration_allowsUpToThreeConcurrentStocks() async throws {
        let recorder = CallRecorder()
        let queue = InitializationQueue { code, step in // default Configuration()
            await recorder.begin(code: code, step: step)
            try await Task.sleep(nanoseconds: 20_000_000)
            await recorder.end()
        }

        await queue.enqueue(["600519", "000001", "300059", "600000"])
        await queue.waitUntilIdle()

        let maxConcurrency = await recorder.maxObservedConcurrency
        XCTAssertLessThanOrEqual(maxConcurrency, 3, "default cap is 3 per plan.md §11")
    }
}
