import Foundation
import WatchConnectivity

final class WatchSyncManager: NSObject {
    static let shared = WatchSyncManager()

    private weak var store: WatchlistStore?

    private override init() {
        super.init()
    }

    @MainActor
    func configure(store: WatchlistStore) {
        self.store = store
        activate()
        applyContext(WCSession.default.receivedApplicationContext)
    }

    private func activate() {
        guard WCSession.isSupported() else {
            print("[WatchSyncManager] WCSession is not supported")
            return
        }

        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    private func applyContext(_ context: [String: Any]) {
        guard let codes = context["watchlist"] as? [String] else {
            return
        }

        print("[WatchSyncManager] Received watchlist: \(codes)")
        Task { @MainActor in
            self.store?.replace(with: codes)
        }
    }
}

extension WatchSyncManager: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            print("[WatchSyncManager] Activation failed: \(error.localizedDescription)")
        } else {
            print("[WatchSyncManager] Activated with state: \(activationState.rawValue)")
            applyContext(session.receivedApplicationContext)
        }
    }

    func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        applyContext(applicationContext)
    }
}
