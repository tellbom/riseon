import Foundation

/// Completes a manual refresh (task.md S12.1) by applying the results of a
/// fresh Step A-E run to a workspace already sitting in `.initializing`.
///
/// The expected flow:
/// 1. Caller moves the workspace into refresh: `try workspace.transition(to: .initializing)`
///    (legal from `.ready`/`.partial`/`.stale`/`.failed`).
/// 2. Caller drives `InitializationQueue.refresh(code)` (S12.1) to re-run
///    Steps A-E, then rebuilds `ContextPack`/`RuleScore` from the fresh
///    data (via `RealtimeOverlay` + `TechnicalIndicators` + `RuleScoreEngine`
///    + `ContextPackBuilder`, wiring not yet assembled into one
///    orchestrator — that's a later task).
/// 3. Caller applies the result here, which updates the snapshot and moves
///    `state` on to `.ready`/`.partial`.
///
/// This intentionally does **not** call `InitializationQueue.refresh`
/// itself, or fetch/compute anything — same "纪律" as `RealtimeOverlay`/
/// `RuleScoreEngine`/`ContextPackBuilder`: it's a pure state-update step,
/// not an orchestrator.
extension StockWorkspace {
    /// - Parameters:
    ///   - pack: the freshly-built `ContextPack` from this refresh run.
    ///   - ruleScore: the freshly-computed `RuleScore`, if the fresh bar
    ///     count was enough to produce one (`RuleScoreEngine.minimumBarsRequired`).
    ///   - snapshotDate: when this fresh data was captured (task.md S12.1's
    ///     "更新快照时间").
    ///   - source: e.g. `"tencent"` — recorded in `meta.source`.
    ///
    /// Throws `WorkspaceTransitionError.illegal` if `state` isn't currently
    /// `.initializing` — this is the second half of a two-step transition
    /// the caller starts (see flow above), not a standalone refresh trigger.
    @discardableResult
    public mutating func applyRefreshedPack(
        _ pack: ContextPack,
        ruleScore: RuleScore?,
        snapshotDate: Date,
        source: String
    ) throws -> WorkspaceState {
        contextPack = pack
        self.ruleScore = ruleScore
        meta = WorkspaceMeta(snapshotDate: snapshotDate, source: source, quality: pack.dataQuality.level)

        let isFullyAvailable = pack.dataQuality.level == "good" || pack.dataQuality.level == "usable"
        return try transition(to: isFullyAvailable ? .ready : .partial)
    }
}
