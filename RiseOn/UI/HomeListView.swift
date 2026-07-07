import SwiftUI

/// Home list (plan.md §4.1). Closes two of the gaps flagged in
/// `S16_MVP验收评估.md`:
/// - task.md S16.1: tapping a row builds (or opens) that stock's
///   `StockWorkspace` and navigates to `InitProgressView` to watch it.
/// - task.md S12.2: a stale workspace's row shows "数据过期，建议刷新"
///   inline, with a swipe action to trigger the actual refresh (S12.1).
///
/// **Composition note for whoever wires this into the app**: `queue` must
/// already be constructed with `coordinator.stepExecutor()` as its
/// `executeStep` — this view doesn't do that wiring itself, so `coordinator`
/// and `queue` need to agree on that at the call site (see this file's
/// `#Preview` for a minimal example, which uses a dummy executor instead
/// since it doesn't need real network access).
struct HomeListView: View {
    @StateObject private var viewModel: HomeListViewModel

    init(
        watchlistStore: WatchlistStore,
        workspaceStore: WorkspaceStore,
        queue: InitializationQueue,
        coordinator: WorkspaceInitializationCoordinator
    ) {
        _viewModel = StateObject(wrappedValue: HomeListViewModel(
            watchlistStore: watchlistStore,
            workspaceStore: workspaceStore,
            queue: queue,
            coordinator: coordinator
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.items.isEmpty {
                    emptyState
                } else {
                    stockList
                }
            }
            .navigationTitle("个股问答")
            .task { await viewModel.refreshWorkspaceStates() }
            .navigationDestination(
                isPresented: Binding(
                    get: { viewModel.selectedCode != nil },
                    set: { isPresented in
                        if !isPresented {
                            viewModel.selectedCode = nil
                        }
                    }
                )
            ) {
                if let code = viewModel.selectedCode {
                    WorkspaceRouteView(
                        code: code,
                        knownState: viewModel.workspaceStates[code],
                        queue: viewModel.queue,
                        workspaceStore: viewModel.workspaceStore
                    )
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "暂无自选股",
            systemImage: "chart.line.uptrend.xyaxis",
            description: Text("先在自选股中添加股票，即可在这里创建问答 Workspace")
        )
        .accessibilityLabel("首页列表为空")
    }

    private var stockList: some View {
        List(viewModel.items) { item in
            HomeStockRowView(
                item: item,
                state: viewModel.workspaceStates[item.code],
                errorMessage: viewModel.errors[item.code]
            )
            .contentShape(Rectangle())
            .onTapGesture {
                Task { await viewModel.openWorkspace(for: item) }
            }
            .swipeActions(edge: .trailing) {
                if viewModel.workspaceStates[item.code] != nil {
                    Button {
                        Task { await viewModel.refreshWorkspace(for: item) }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .tint(.orange)
                }
            }
        }
        .accessibilityLabel("首页股票列表")
        .refreshable { await viewModel.refreshWorkspaceStates() }
    }
}

private struct WorkspaceRouteView: View {
    let code: String
    let queue: InitializationQueue
    let workspaceStore: WorkspaceStore

    @State private var state: WorkspaceState?

    /// - Parameter knownState: whatever `HomeListViewModel` already knew
    ///   about this stock's state (from the row it was just tapped from).
    ///   Seeding `state` with it avoids a spurious flash of
    ///   `InitProgressView` for a stock that's already `.ready`/`.partial`/
    ///   `.stale` — without this, `state` starts `nil` and the `switch`
    ///   below defaults to `InitProgressView` until `loadState()`'s async
    ///   disk read resolves, even though the caller already knew better.
    ///   Still re-verified via `loadState()` below (e.g. first-ever open,
    ///   where `knownState` is genuinely `nil`, correctly falls through to
    ///   `InitProgressView` since the stock really is initializing).
    init(code: String, knownState: WorkspaceState?, queue: InitializationQueue, workspaceStore: WorkspaceStore) {
        self.code = code
        self.queue = queue
        self.workspaceStore = workspaceStore
        _state = State(initialValue: knownState)
    }

    var body: some View {
        Group {
            switch state {
            case .ready, .partial, .stale:
                WorkspaceDetailView(code: code, workspaceStore: workspaceStore)
            default:
                InitProgressView(code: code, queue: queue, workspaceStore: workspaceStore)
            }
        }
        .task { await loadState() }
    }

    private func loadState() async {
        let workspace = try? await workspaceStore.load(code: code)
        state = workspace?.state
    }
}

private struct HomeStockRowView: View {
    let item: WatchlistItem
    let state: WorkspaceState?
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if !item.name.isEmpty {
                        Text(item.name)
                    }
                    Text(item.code)
                        .font(item.name.isEmpty ? .body.monospacedDigit() : .caption.monospacedDigit())
                        .foregroundStyle(item.name.isEmpty ? .primary : .secondary)
                }
                Spacer()
                statusBadge
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
            }

            // "数据过期，建议刷新" -- task.md S12.2's exact required wording.
            // Informational only; the actual refresh action lives in this
            // row's trailing swipe action, not here, to avoid nesting a
            // tappable control inside the row's own tap target.
            if state == .stale {
                Label("数据过期，建议刷新", systemImage: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch state {
        case .none, .uninitialized:
            EmptyView()
        case .initializing:
            ProgressView().controlSize(.small)
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .partial:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .stale:
            Image(systemName: "clock.badge.exclamationmark.fill").foregroundStyle(.orange)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private var accessibilityLabel: String {
        let base = "\(item.name.isEmpty ? item.code : item.name)，代码 \(item.code)"
        switch state {
        case .none, .uninitialized:
            return "\(base)，尚未建立 Workspace，点击建立"
        case .initializing:
            return "\(base)，初始化中"
        case .ready:
            return "\(base)，已就绪"
        case .partial:
            return "\(base)，部分就绪"
        case .stale:
            return "\(base)，数据过期，建议刷新"
        case .failed:
            return "\(base)，初始化失败"
        }
    }
}

#Preview {
    let watchlistStore = WatchlistStore(key: "preview_workspace_home")
    let workspaceStore = try! WorkspaceStore(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("preview-workspaces-\(UUID().uuidString)")
    )
    let coordinator = WorkspaceInitializationCoordinator(workspaceStore: workspaceStore)
    // Preview-only dummy executor -- a real composition root wires
    // `coordinator.stepExecutor()` in here instead.
    let queue = InitializationQueue { _, _ in
        try await Task.sleep(nanoseconds: 300_000_000)
    }
    return HomeListView(
        watchlistStore: watchlistStore,
        workspaceStore: workspaceStore,
        queue: queue,
        coordinator: coordinator
    )
}
