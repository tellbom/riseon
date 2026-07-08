import XCTest
@testable import RiseOn

/// Covers task.md S16.1-S16.3's actual end-to-end path: create a workspace,
/// run it through the real `InitializationQueue` with
/// `WorkspaceInitializationCoordinator.stepExecutor()`, and confirm it lands
/// on a correctly-populated, correctly-stated `StockWorkspace`. Network
/// providers are mocked (`DailyBarsProvider`/`QuoteProvider` are both
/// protocols specifically so this is possible); everything else — the
/// queue, the store, `TechnicalIndicators`, `RuleScoreEngine`,
/// `ContextPackBuilder` — is the real thing.
final class WorkspaceInitializationCoordinatorTests: XCTestCase {

    // MARK: - Mocks

    private actor MockDailyBarsProvider: DailyBarsProvider {
        enum Behavior { case succeed([DailyBar]), fail }
        private let behavior: Behavior
        init(_ behavior: Behavior) { self.behavior = behavior }
        func fetchDailyBars(fullSymbol: String, start: String, end: String, lookback: Int) async throws -> [DailyBar] {
            switch behavior {
            case .succeed(let bars): return bars
            case .fail: throw MockProviderError.simulatedFailure
            }
        }
    }

    private actor MockQuoteProvider: QuoteProvider {
        enum Behavior { case succeed(Quote), fail }
        private let behavior: Behavior
        init(_ behavior: Behavior) { self.behavior = behavior }
        func fetchQuote(for symbol: StockSymbol) async throws -> Quote {
            switch behavior {
            case .succeed(let quote): return quote
            case .fail: throw MockProviderError.simulatedFailure
            }
        }
    }

    private struct MockProviderError: Error { static let simulatedFailure = MockProviderError() }

    /// External factors aren't the focus of these end-to-end tests (they have
    /// their own coverage in `ExternalFactorCollectorTests`/
    /// `ContextPackBuilderExternalTests`), and the real
    /// `ExternalFactorCollector` would fire live network calls here. This
    /// stub returns an empty bundle instantly so these tests stay
    /// deterministic and offline — the quote/daily/technical/levels/quality
    /// assertions below are unaffected by an empty external bundle.
    private struct MockExternalCollector: ExternalFactorCollecting {
        func collect(code: String, todayYYYYMMDD: String) async -> ExternalFactorBundle {
            ExternalFactorBundle()
        }
    }

    // MARK: - Fixtures

    private func makeBars(count: Int = 30) -> [DailyBar] {
        (0..<count).map { i in
            let close = 10.0 + Double(i) * 0.1
            return DailyBar(date: "2024-06-\(String(format: "%02d", (i % 28) + 1))", open: close, close: close, high: close + 0.1, low: close - 0.1, volume: 10_000)
        }
    }

    private func makeQuote(price: Double = 13.0) -> Quote {
        guard let symbol = StockSymbol(code: "600519") else { fatalError("600519 must be valid") }
        return Quote(
            symbol: symbol, name: "贵州茅台", price: price, previousClose: 12.9,
            open: 12.95, high: 13.1, low: 12.9, changeAmount: price - 12.9,
            changePercent: (price - 12.9) / 12.9 * 100, updatedAt: Date(), orderBook: nil
        )
    }

    private func makeTempWorkspaceStore() throws -> WorkspaceStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try WorkspaceStore(directory: directory)
    }

    // MARK: - Happy path

    func test_fullPipeline_allStepsSucceed_workspaceReachesReadyWithPopulatedPack() async throws {
        let store = try makeTempWorkspaceStore()
        let coordinator = WorkspaceInitializationCoordinator(
            workspaceStore: store,
            dailyProvider: MockDailyBarsProvider(.succeed(makeBars())),
            quoteProvider: MockQuoteProvider(.succeed(makeQuote())),
            externalCollector: MockExternalCollector(),
            isTradingDayToday: { true }
        )
        let queue = InitializationQueue(executeStep: coordinator.stepExecutor())

        let started = try await coordinator.startInitialization(code: "600519", name: "贵州茅台", market: "sh", queue: queue)
        XCTAssertTrue(started)
        await queue.waitUntilIdle()

        XCTAssertEqual(await queue.outcome(for: "600519"), .succeeded)

        let workspace = try await store.load(code: "600519")
        XCTAssertEqual(workspace?.state, .ready)
        XCTAssertNotNil(workspace?.contextPack)
        XCTAssertNotNil(workspace?.ruleScore)
        XCTAssertEqual(workspace?.contextPack?.blocks[ContextBlockKey.quote]?.status, .available)
        XCTAssertEqual(workspace?.contextPack?.blocks[ContextBlockKey.dailyBars]?.status, .available)
        XCTAssertEqual(workspace?.contextPack?.blocks[ContextBlockKey.technical]?.status, .available)
        XCTAssertEqual(workspace?.contextPack?.blocks[ContextBlockKey.levels]?.status, .available)
        XCTAssertEqual(workspace?.contextPack?.dataQuality.level, "good")
    }

    // MARK: - Degradation (S15.1 exercised end-to-end)

    func test_dailyBarsFetchFails_cascadesGracefully_stillReachesPartial() async throws {
        let store = try makeTempWorkspaceStore()
        let coordinator = WorkspaceInitializationCoordinator(
            workspaceStore: store,
            dailyProvider: MockDailyBarsProvider(.fail),
            quoteProvider: MockQuoteProvider(.succeed(makeQuote())),
            externalCollector: MockExternalCollector(),
            isTradingDayToday: { true }
        )
        let queue = InitializationQueue(executeStep: coordinator.stepExecutor())

        try await coordinator.startInitialization(code: "600519", name: "贵州茅台", market: "sh", queue: queue)
        await queue.waitUntilIdle()

        // Steps C/D/E don't throw just because there's no data -- they run
        // on empty input and the pipeline still completes (task.md S15.1:
        // "不阻塞 ready").
        XCTAssertEqual(await queue.outcome(for: "600519"), .succeeded)

        let workspace = try await store.load(code: "600519")
        XCTAssertEqual(workspace?.state, .partial, "断网初始化仍能进入部分就绪")
        XCTAssertEqual(workspace?.contextPack?.blocks[ContextBlockKey.dailyBars]?.status, .fetchFailed)
        XCTAssertEqual(workspace?.contextPack?.blocks[ContextBlockKey.technical]?.status, .fetchFailed, "must cascade, not show a generic missing")
        XCTAssertEqual(workspace?.contextPack?.blocks[ContextBlockKey.levels]?.status, .fetchFailed)
        // Quote itself still succeeded independently of daily bars failing.
        XCTAssertEqual(workspace?.contextPack?.blocks[ContextBlockKey.quote]?.status, .available)
    }

    func test_quoteFetchFails_dailyBarsStillAvailable_qualityDegradesButCompletes() async throws {
        let store = try makeTempWorkspaceStore()
        let coordinator = WorkspaceInitializationCoordinator(
            workspaceStore: store,
            dailyProvider: MockDailyBarsProvider(.succeed(makeBars())),
            quoteProvider: MockQuoteProvider(.fail),
            externalCollector: MockExternalCollector(),
            isTradingDayToday: { true }
        )
        let queue = InitializationQueue(executeStep: coordinator.stepExecutor())

        try await coordinator.startInitialization(code: "600519", name: "贵州茅台", market: "sh", queue: queue)
        await queue.waitUntilIdle()

        XCTAssertEqual(await queue.outcome(for: "600519"), .succeeded)
        let workspace = try await store.load(code: "600519")
        XCTAssertEqual(workspace?.contextPack?.blocks[ContextBlockKey.quote]?.status, .fetchFailed)
        XCTAssertEqual(workspace?.contextPack?.blocks[ContextBlockKey.dailyBars]?.status, .available)
        // Overall still lands on ready or partial, never stuck.
        XCTAssertTrue(workspace?.state == .ready || workspace?.state == .partial)
    }

    func test_bothFetchesFail_stillReachesPartial_neverStuck() async throws {
        let store = try makeTempWorkspaceStore()
        let coordinator = WorkspaceInitializationCoordinator(
            workspaceStore: store,
            dailyProvider: MockDailyBarsProvider(.fail),
            quoteProvider: MockQuoteProvider(.fail),
            externalCollector: MockExternalCollector(),
            isTradingDayToday: { true }
        )
        let queue = InitializationQueue(executeStep: coordinator.stepExecutor())

        try await coordinator.startInitialization(code: "600519", name: "贵州茅台", market: "sh", queue: queue)
        await queue.waitUntilIdle()

        XCTAssertEqual(await queue.outcome(for: "600519"), .succeeded, "the pipeline itself must still finish")
        let workspace = try await store.load(code: "600519")
        XCTAssertEqual(workspace?.state, .partial)
        XCTAssertEqual(workspace?.contextPack?.dataQuality.level, "poor")
    }

    // MARK: - startInitialization semantics

    func test_startInitialization_secondCallOnSameCode_isNoOp() async throws {
        let store = try makeTempWorkspaceStore()
        let coordinator = WorkspaceInitializationCoordinator(
            workspaceStore: store,
            dailyProvider: MockDailyBarsProvider(.succeed(makeBars())),
            quoteProvider: MockQuoteProvider(.succeed(makeQuote())),
            externalCollector: MockExternalCollector(),
            isTradingDayToday: { true }
        )
        let queue = InitializationQueue(executeStep: coordinator.stepExecutor())

        let first = try await coordinator.startInitialization(code: "600519", name: "贵州茅台", market: "sh", queue: queue)
        XCTAssertTrue(first)
        // Second call before the first has even finished -- workspace is
        // already past `.uninitialized` (it's `.initializing`), so this
        // must not re-transition or double-enqueue.
        let second = try await coordinator.startInitialization(code: "600519", name: "贵州茅台", market: "sh", queue: queue)
        XCTAssertFalse(second)

        await queue.waitUntilIdle()
        XCTAssertEqual(await queue.outcome(for: "600519"), .succeeded)
    }

    func test_unresolvableCode_doesNotCrash_marksMissingRatherThanFetchFailed() async throws {
        // Not a real 6-digit code -- `ACodeResolver`/`StockSymbol` can't
        // resolve it at all. Must degrade gracefully, not throw out of the
        // step executor entirely.
        let store = try makeTempWorkspaceStore()
        let coordinator = WorkspaceInitializationCoordinator(
            workspaceStore: store,
            dailyProvider: MockDailyBarsProvider(.succeed(makeBars())),
            quoteProvider: MockQuoteProvider(.succeed(makeQuote())),
            externalCollector: MockExternalCollector(),
            isTradingDayToday: { true }
        )
        let queue = InitializationQueue(executeStep: coordinator.stepExecutor())

        try await coordinator.startInitialization(code: "BADCODE", name: "无效代码", market: "sh", queue: queue)
        await queue.waitUntilIdle()

        XCTAssertEqual(await queue.outcome(for: "BADCODE"), .succeeded)
        let workspace = try await store.load(code: "BADCODE")
        XCTAssertEqual(workspace?.contextPack?.blocks[ContextBlockKey.dailyBars]?.status, .missing, "unresolvable code is missing, not fetch_failed -- no attempt was ever made")
    }
}
