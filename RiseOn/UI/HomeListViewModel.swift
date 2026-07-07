import Foundation
import Combine

/// Drives `HomeListView` (task.md S16.1's "从自选股一键建 Workspace" gap,
/// and S12.2's staleness-hint gap — both closed together here since they
/// share the same "load workspace state for each watchlist item" logic).
@MainActor
public final class HomeListViewModel: ObservableObject {
    @Published public private(set) var items: [WatchlistItem] = []
    /// Per-code `StockWorkspace.state`, for whichever codes already have a
    /// workspace on disk. Absent entries just mean "no workspace built yet".
    @Published public private(set) var workspaceStates: [String: WorkspaceState] = [:]
    @Published public private(set) var errors: [String: String] = [:]
    /// Drives navigation to `InitProgressView` — set after successfully
    /// kicking off a build/refresh, `nil` otherwise.
    @Published public var selectedCode: String?

    private let watchlistStore: WatchlistStore
    public let workspaceStore: WorkspaceStore
    public let queue: InitializationQueue
    private let coordinator: WorkspaceInitializationCoordinator

    public init(
        watchlistStore: WatchlistStore,
        workspaceStore: WorkspaceStore,
        queue: InitializationQueue,
        coordinator: WorkspaceInitializationCoordinator
    ) {
        self.watchlistStore = watchlistStore
        self.workspaceStore = workspaceStore
        self.queue = queue
        self.coordinator = coordinator
        watchlistStore.$items.assign(to: &$items)
    }

    // MARK: - S16.1: "一键建 Workspace"

    /// Starts initialization for `item` if it's never been built before,
    /// then navigates to the progress screen either way — opening an
    /// already-settled workspace's progress screen is harmless
    /// (`InitProgressViewModel` just reflects its final state immediately).
    public func openWorkspace(for item: WatchlistItem) async {
        errors[item.code] = nil

        guard let market = ACodeResolver.market(for: item.code)?.rawValue else {
            errors[item.code] = "无法识别股票代码所属市场"
            return
        }

        do {
            try await coordinator.startInitialization(code: item.code, name: item.name, market: market, queue: queue)
        } catch {
            errors[item.code] = "创建 Workspace 失败：\(error.localizedDescription)"
            return
        }
        selectedCode = item.code
    }

    // MARK: - S12.2: staleness hint ("数据过期，建议刷新")

    /// Loads each watchlisted code's workspace state, evaluating (and
    /// persisting) staleness along the way — this is what actually *drives*
    /// `StockWorkspace.evaluateStaleness` (S12.2); nothing else in the app
    /// calls it on a schedule, so the Home screen's own appearance is the
    /// natural trigger point. Call from `.task { await viewModel.refreshWorkspaceStates() }`.
    public func refreshWorkspaceStates() async {
        var result: [String: WorkspaceState] = [:]
        let tradingDay = Self.mostRecentTradingDay()

        for item in items {
            guard var workspace = try? await workspaceStore.load(code: item.code) else { continue }
            if let becameStale = try? workspace.evaluateStaleness(mostRecentTradingDay: tradingDay), becameStale {
                try? await workspaceStore.save(workspace)
            }
            result[item.code] = workspace.state
        }
        workspaceStates = result
    }

    /// Manual refresh (task.md S12.1) triggered from the staleness hint
    /// (S12.2) or any other "refresh this stock" affordance: moves the
    /// workspace back to `.initializing` and re-drives the queue, then
    /// navigates to the progress screen so the person can watch it.
    ///
    /// A workspace can already be sitting at `.initializing` when this is
    /// called — either a previous refresh is still genuinely running, or an
    /// earlier run never made it to `.ready`/`.partial`/`.failed` (nothing in
    /// the init pipeline writes a terminal state back to the workspace on
    /// failure, so it's left at `.initializing` indefinitely). `.initializing
    /// -> .initializing` isn't a legal transition, so re-running it
    /// unconditionally used to throw `WorkspaceTransitionError` and get stuck
    /// there forever (surfaced to the user as a raw, untranslated error) --
    /// skip the no-op transition in that case and just re-drive the queue,
    /// which is what actually needs to happen either way.
    public func refreshWorkspace(for item: WatchlistItem) async {
        errors[item.code] = nil
        do {
            guard var workspace = try await workspaceStore.load(code: item.code) else {
                errors[item.code] = "还没有可刷新的 Workspace"
                return
            }
            if workspace.state != .initializing {
                try workspace.transition(to: .initializing)
                try await workspaceStore.save(workspace)
            }
            do {
                _ = try await queue.refresh(item.code)
            } catch InitializationQueue.RefreshError.alreadyActive {
                // A refresh is already running for this code -- nothing to
                // do, let it finish on its own.
            }
        } catch {
            errors[item.code] = "刷新失败：\(error.localizedDescription)"
            return
        }
        selectedCode = item.code
    }

    /// Weekday-only approximation (no public-holiday calendar) -- same
    /// known limitation as `WorkspaceInitializationCoordinator.defaultIsTradingDayToday`
    /// (a real trading calendar doesn't exist yet in this project).
    private static func mostRecentTradingDay(calendar: Calendar = .current) -> Date {
        var date = Date()
        while true {
            let weekday = calendar.component(.weekday, from: date)
            if weekday != 1, weekday != 7 { // not Sunday(1) or Saturday(7)
                return calendar.startOfDay(for: date)
            }
            date = calendar.date(byAdding: .day, value: -1, to: date) ?? date
        }
    }
}
