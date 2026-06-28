import Foundation
import WatchConnectivity

final class PhoneSyncManager: NSObject {
    static let shared = PhoneSyncManager()

    private var pendingCodes: [String]?

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
        guard WCSession.isSupported() else {
            return
        }

        let session = WCSession.default
        guard session.activationState == .activated else {
            pendingCodes = codes
            print("[PhoneSyncManager] Session is not activated; skipping watchlist push")
            return
        }

        do {
            try session.updateApplicationContext(["watchlist": codes])
            print("[PhoneSyncManager] Pushed watchlist: \(codes)")
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
            if let pendingCodes {
                self.pendingCodes = nil
                push(codes: pendingCodes)
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
