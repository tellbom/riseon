//
//  StocksApp.swift
//  Stocks Watch App
//
//  Created by 付子强 on 6/28/26.
//

import SwiftUI

@main
struct Stocks_Watch_AppApp: App {
    @StateObject private var store = WatchlistStore()

    var body: some Scene {
        WindowGroup {
            WatchlistWatchView(store: store)
                .onAppear {
                    WatchSyncManager.shared.configure(store: store)
                }
        }
    }
}
