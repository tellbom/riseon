import XCTest
@testable import RiseOn

/// Covers the view-model logic behind the two gaps closed this round:
/// task.md S16.1 ("一键建 Workspace" from the Home list) and S12.2's
/// staleness hint. SwiftUI rendering itself still needs an actual
/// device/simulator look, per this project's established pattern for UI
/// files (`InitProgressViewModel`/`HomeListView` from S1/S13 were tested the
/// same way) — this covers the state management the view reads from.
@MainActor
final class HomeListViewModelTests: XCTestCase {

    private actor MockDailyBarsProvider: DailyBarsProvider {
        func fetchDailyBars(fullSymbol: String, start: String, end: String, lookback: Int) async throws -> [DailyBar] {
            (0..<30).map { i in
                let close = 10.0 + Double(i) * 0.1
                return DailyBar(date: "2024-06-\(String(format: "%02d", (i % 28) + 1))", open: close, close: close, high: close + 0.1, low: close - 0.1, volume: 10_000)
            }
        }
    }

    private actor MockQuoteProvider: QuoteProvider {
        func fetchQuote(for symbol: StockSymbol) async throws -> Quote {
            Quote(symbol: symbol, name: "", price: 13, previousClose: 12.9, open: 12.95, high: 13.1, low: 12.9, changeAmount: 0.1, changePercent: 0.8, updatedAt: Date(), orderBook: nil)
        }
    }

    private func makeStores() throws -> (watchlist: WatchlistStore, workspace: WorkspaceStore) {
        let watchlistStore = WatchlistStore(key: "HomeListViewModelTests-\(UUID().uuidString)")
        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HomeListViewModelTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: workspaceDirectory) }
        let workspaceStore = try WorkspaceStore(directory: workspaceDirectory)
        return (watchlistStore, workspaceStore)
    }

    private func makeViewModel(watchlistStore: WatchlistStore, workspaceStore: WorkspaceStore) async -> (HomeListViewModel, InitializationQueue) {
        let coordinator = WorkspaceInitializationCoordinator(
            workspaceStore: workspaceStore,
            dailyProvider: MockDailyBarsProvider(),
            quoteProvider: MockQuoteProvider(),
            isTradingDayToday: { true }
        )
        let queue = InitializationQueue(executeStep: coordinator.stepExecutor())
        let viewModel = HomeListViewModel(watchlistStore: watchlistStore, workspaceStore: workspaceStore, queue: queue, coordinator: coordinator)
        return (viewModel, queue)
    }

    // MARK: - S16.1: build workspace + navigate

    func test_openWorkspace_startsInitializationAndSetsSelectedCode() async throws {
        let (watchlistStore, workspaceStore) = try makeStores()
        watchlistStore.add(code: "600519", name: "贵州茅台")
        let (viewModel, queue) = await makeViewModel(watchlistStore: watchlistStore, workspaceStore: workspaceStore)

        await viewModel.openWorkspace(for: WatchlistItem(code: "600519", name: "贵州茅台"))

        XCTAssertEqual(viewModel.selectedCode, "600519")
        await queue.waitUntilIdle()
        let workspace = try await workspaceStore.load(code: "600519")
        XCTAssertEqual(workspace?.state, .ready)
        XCTAssertNil(viewModel.errors["600519"])
    }

    func test_openWorkspace_unresolvableMarket_recordsErrorAndDoesNotNavigate() async throws {
        let (watchlistStore, workspaceStore) = try makeStores()
        let (viewModel, _) = await makeViewModel(watchlistStore: watchlistStore, workspaceStore: workspaceStore)

        // Not a valid 6-digit code -- ACodeResolver can't resolve a market.
        await viewModel.openWorkspace(for: WatchlistItem(code: "BAD", name: "无效"))

        XCTAssertNil(viewModel.selectedCode)
        XCTAssertNotNil(viewModel.errors["BAD"])
    }

    func test_openWorkspace_onAlreadyBuiltWorkspace_stillNavigates_doesNotRebuild() async throws {
        let (watchlistStore, workspaceStore) = try makeStores()
        let (viewModel, queue) = await makeViewModel(watchlistStore: watchlistStore, workspaceStore: workspaceStore)
        let item = WatchlistItem(code: "600519", name: "贵州茅台")

        await viewModel.openWorkspace(for: item)
        await queue.waitUntilIdle()
        XCTAssertEqual(try await workspaceStore.load(code: "600519")?.state, .ready)

        viewModel.selectedCode = nil // simulate having navigated back
        await viewModel.openWorkspace(for: item) // tap the same row again

        XCTAssertEqual(viewModel.selectedCode, "600519", "must still navigate even though nothing needed to build")
        XCTAssertEqual(try await workspaceStore.load(code: "600519")?.state, .ready, "must not have been reset/rebuilt")
    }

    // MARK: - S12.2: staleness hint

    func test_refreshWorkspaceStates_detectsAndPersistsStaleness() async throws {
        let (watchlistStore, workspaceStore) = try makeStores()
        watchlistStore.add(code: "600519", name: "贵州茅台")

        // Pre-seed an old, ready workspace directly (as if it had been
        // built a while ago and never reopened since).
        var workspace = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh")
        try workspace.transition(to: .initializing)
        try workspace.applyRefreshedPack(
            ContextPack(subject: ContextPackSubject(code: "600519"), dataQuality: DataQuality(level: "good")),
            ruleScore: nil,
            snapshotDate: Calendar.current.date(byAdding: .day, value: -10, to: Date())!,
            source: "tencent"
        )
        try await workspaceStore.save(workspace)

        let (viewModel, _) = await makeViewModel(watchlistStore: watchlistStore, workspaceStore: workspaceStore)
        await viewModel.refreshWorkspaceStates()

        XCTAssertEqual(viewModel.workspaceStates["600519"], .stale)
        // Must actually be persisted, not just reflected in memory.
        let reloaded = try await workspaceStore.load(code: "600519")
        XCTAssertEqual(reloaded?.state, .stale)
    }

    func test_refreshWorkspaceStates_freshSnapshot_doesNotBecomeStale() async throws {
        let (watchlistStore, workspaceStore) = try makeStores()
        watchlistStore.add(code: "600519", name: "贵州茅台")

        var workspace = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh")
        try workspace.transition(to: .initializing)
        try workspace.applyRefreshedPack(
            ContextPack(subject: ContextPackSubject(code: "600519"), dataQuality: DataQuality(level: "good")),
            ruleScore: nil,
            snapshotDate: Date(),
            source: "tencent"
        )
        try await workspaceStore.save(workspace)

        let (viewModel, _) = await makeViewModel(watchlistStore: watchlistStore, workspaceStore: workspaceStore)
        await viewModel.refreshWorkspaceStates()

        XCTAssertEqual(viewModel.workspaceStates["600519"], .ready)
    }

    func test_refreshWorkspaceStates_noWorkspaceYet_isAbsentNotCrashing() async throws {
        let (watchlistStore, workspaceStore) = try makeStores()
        watchlistStore.add(code: "600519", name: "贵州茅台") // watchlisted, but no workspace built

        let (viewModel, _) = await makeViewModel(watchlistStore: watchlistStore, workspaceStore: workspaceStore)
        await viewModel.refreshWorkspaceStates()

        XCTAssertNil(viewModel.workspaceStates["600519"])
    }

    // MARK: - S12.1: manual refresh from the hint

    func test_refreshWorkspace_onStaleWorkspace_movesThroughInitializingBackToReady() async throws {
        let (watchlistStore, workspaceStore) = try makeStores()
        var workspace = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh")
        try workspace.transition(to: .initializing)
        try workspace.applyRefreshedPack(
            ContextPack(subject: ContextPackSubject(code: "600519"), dataQuality: DataQuality(level: "good")),
            ruleScore: nil,
            snapshotDate: Calendar.current.date(byAdding: .day, value: -10, to: Date())!,
            source: "tencent"
        )
        try workspace.transition(to: .stale)
        try await workspaceStore.save(workspace)

        let (viewModel, queue) = await makeViewModel(watchlistStore: watchlistStore, workspaceStore: workspaceStore)
        await viewModel.refreshWorkspace(for: WatchlistItem(code: "600519", name: "贵州茅台"))

        XCTAssertEqual(viewModel.selectedCode, "600519")
        await queue.waitUntilIdle()

        let reloaded = try await workspaceStore.load(code: "600519")
        XCTAssertEqual(reloaded?.state, .ready)
        XCTAssertNil(viewModel.errors["600519"])
    }

    /// Reproduces the reported bug: a workspace left at `.initializing`
    /// (e.g. a previous run that never finished/settled) must still be
    /// refreshable -- `.initializing -> .initializing` isn't a legal
    /// `StockWorkspace` transition, so refreshing used to throw
    /// `WorkspaceTransitionError` and get permanently stuck (surfaced to the
    /// user as an untranslated "the operation couldn't be completed").
    func test_refreshWorkspace_onWorkspaceStuckInitializing_stillSucceeds() async throws {
        let (watchlistStore, workspaceStore) = try makeStores()
        var workspace = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh")
        try workspace.transition(to: .initializing)
        try await workspaceStore.save(workspace)

        let (viewModel, queue) = await makeViewModel(watchlistStore: watchlistStore, workspaceStore: workspaceStore)
        await viewModel.refreshWorkspace(for: WatchlistItem(code: "600519", name: "贵州茅台"))

        XCTAssertNil(viewModel.errors["600519"])
        XCTAssertEqual(viewModel.selectedCode, "600519")
        await queue.waitUntilIdle()

        let reloaded = try await workspaceStore.load(code: "600519")
        XCTAssertEqual(reloaded?.state, .ready)
    }

    func test_refreshWorkspace_noExistingWorkspace_recordsErrorRatherThanCrashing() async throws {
        let (watchlistStore, workspaceStore) = try makeStores()
        let (viewModel, _) = await makeViewModel(watchlistStore: watchlistStore, workspaceStore: workspaceStore)

        await viewModel.refreshWorkspace(for: WatchlistItem(code: "600519", name: "贵州茅台"))

        XCTAssertNotNil(viewModel.errors["600519"])
        XCTAssertNil(viewModel.selectedCode)
    }
}
