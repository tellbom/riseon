import Foundation

/// Known warning keys that get written into `ContextPack`'s data-quality
/// warnings list once S8 builds that field (`ContextPackBuilder`, task.md
/// S8.2). Defined now, ahead of S8, so `RealtimeOverlay` (S5.2) and the
/// future `ContextPackBuilder` share the exact same string literals instead
/// of each side re-typing them and risking a mismatch.
public enum ContextPackWarningKey {
    /// Realtime overlay only updates price fields; the daily bar's `volume`
    /// is left at its original value (plan.md §0.5-4).
    public static let intradayVolumeOverlaySkipped = "intraday_volume_overlay_skipped"

    /// The daily endpoint hadn't published today's bar yet at overlay time,
    /// so no synthetic bar was appended for it (plan.md §0.5-7).
    public static let intradayBarNotYetAvailable = "intraday_bar_not_yet_available"

    /// No realtime overlay was attempted at all this run — e.g. the quote
    /// fetch failed, or the code can't be resolved by the shared
    /// `StockSymbol`/`QuoteProvider` (S16's `WorkspaceInitializationCoordinator`
    /// documents both cases). Distinct from `intradayVolumeOverlaySkipped`,
    /// which is about volume specifically and is always true regardless of
    /// whether the *price* overlay itself succeeded.
    public static let realtimeOverlayUnavailable = "realtime_overlay_unavailable"
}
