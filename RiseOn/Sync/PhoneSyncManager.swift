import Foundation
import WatchConnectivity

final class PhoneSyncManager: NSObject {
    static let shared = PhoneSyncManager()

    private var pendingItems: [WatchlistItem]?

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else {
            print("[PhoneSyncManager] WCSession is not supported")
            return
        }

        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func push(codes: [String]) {
        push(items: codes.map { WatchlistItem(code: $0) })
    }

    func push(items: [WatchlistItem]) {
        guard WCSession.isSupported() else {
            return
        }

        let session = WCSession.default
        guard session.activationState == .activated else {
            pendingItems = items
            print("[PhoneSyncManager] Session is not activated; skipping watchlist push")
            return
        }

        let payload = items.map { ["code": $0.code, "name": $0.name] }
        do {
            try session.updateApplicationContext(["watchlist_items": payload])
            print("[PhoneSyncManager] Pushed watchlist items: \(items.map(\.code))")
        } catch {
            print("[PhoneSyncManager] Failed to push watchlist: \(error.localizedDescription)")
        }
    }
}

extension PhoneSyncManager: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            print("[PhoneSyncManager] Activation failed: \(error.localizedDescription)")
        } else {
            print("[PhoneSyncManager] Activated with state: \(activationState.rawValue)")
            if let pendingItems {
                self.pendingItems = nil
                push(items: pendingItems)
            }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        print("[PhoneSyncManager] Session became inactive")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        print("[PhoneSyncManager] Session deactivated; reactivating")
        WCSession.default.activate()
    }
}
