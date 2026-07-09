import Foundation
import WatchConnectivity

final class PhoneSyncManager: NSObject {
    static let shared = PhoneSyncManager()

    private var latestItems: [WatchlistItem]?

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
        latestItems = items

        guard WCSession.isSupported() else {
            return
        }

        let session = WCSession.default
        guard session.activationState == .activated else {
            print("[PhoneSyncManager] Session is not activated; will push watchlist after activation")
            return
        }

        let context = WatchlistSyncPayload.context(for: items)
        do {
            try session.updateApplicationContext(context)
            print("[PhoneSyncManager] Updated watchlist context: \(items.map(\.code))")
        } catch {
            print("[PhoneSyncManager] Failed to update watchlist context: \(error.localizedDescription)")
        }

        guard session.isPaired, session.isWatchAppInstalled else {
            print("[PhoneSyncManager] Watch is not paired or watch app is not installed")
            return
        }

        let transfer = session.transferUserInfo(context)
        print("[PhoneSyncManager] Queued watchlist transfer: \(transfer.isTransferring)")

        if session.isReachable {
            session.sendMessage(context, replyHandler: nil) { error in
                print("[PhoneSyncManager] Failed to send live watchlist message: \(error.localizedDescription)")
            }
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
            if let latestItems {
                push(items: latestItems)
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
