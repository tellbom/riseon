//
//  RiseOnApp.swift
//  RiseOn
//
//  Created by 付子强 on 6/28/26.
//

import SwiftUI

@main
struct RiseOnApp: App {
    @StateObject private var store = WatchlistStore()
    private let workspaceStore: WorkspaceStore
    private let coordinator: WorkspaceInitializationCoordinator
    private let queue: InitializationQueue

    init() {
        let workspaceStore = try! WorkspaceStore()
        let coordinator = WorkspaceInitializationCoordinator(workspaceStore: workspaceStore)
        self.workspaceStore = workspaceStore
        self.coordinator = coordinator
        self.queue = InitializationQueue(
            store: try? InitQueueStore(),
            executeStep: coordinator.stepExecutor()
        )
        PhoneSyncManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(
                watchlistStore: store,
                workspaceStore: workspaceStore,
                queue: queue,
                coordinator: coordinator
            )
                .onReceive(store.$items) { items in
                    PhoneSyncManager.shared.push(items: items)
                }
                .task {
                    try? await queue.restoreFromPersistedState()
                }
        }
    }
}

private struct AppRootView: View {
    let watchlistStore: WatchlistStore
    let workspaceStore: WorkspaceStore
    let queue: InitializationQueue
    let coordinator: WorkspaceInitializationCoordinator

    var body: some View {
        TabView {
            HomeListView(
                watchlistStore: watchlistStore,
                workspaceStore: workspaceStore,
                queue: queue,
                coordinator: coordinator
            )
            .tabItem {
                Label("问答", systemImage: "message")
            }

            WatchlistView(store: watchlistStore)
                .tabItem {
                    Label("自选股", systemImage: "star")
                }
        }
    }
}
