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

    init() {
        PhoneSyncManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchlistView(store: store)
                .onReceive(store.$codes) { codes in
                    PhoneSyncManager.shared.push(codes: codes)
                }
        }
    }
}
