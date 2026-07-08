import Foundation

/// Block-name constants for `ContextPack.blocks`, mirroring the keys
/// `src/services/analysis_context_builder.py::AnalysisContextBuilder.build`
/// uses (`"quote"`, `"daily_bars"`, `"technical"`, `"news"`,
/// `"fundamentals"`, `"chip"`), plus two blocks that don't exist on the
/// Python side but do here: `levels` (S7.3's support/resistance, feeding
/// LLM-generated sniper points per plan.md §0.5-1) and the always-
/// `not_supported` `capital_flow`/`events` blocks plan.md §7 calls for.
///
/// Centralized here (rather than repeating string literals in
/// `ContextPackBuilder` and, later, `PromptBuilder`) so both sides can't
/// drift out of sync on spelling.
public enum ContextBlockKey {
    public static let quote = "quote"
    public static let dailyBars = "daily_bars"
    public static let technical = "technical"
    public static let factors = "factors"
    public static let levels = "levels"
    public static let chip = "chip"
    public static let fundamentals = "fundamentals"
    public static let news = "news"
    public static let capitalFlow = "capital_flow"
    public static let events = "events"

    // On-device external factors (feasibility review): dimensions the MVP
    // left permanently `not_supported` but which are now fetched directly
    // over public HTTPS JSON (see `ExternalData/`). `capital_flow` and
    // `fundamentals` already existed above and get upgraded from
    // `not_supported` to real data when the external bundle is present.
    public static let valuation = "valuation"
    public static let dragonTiger = "dragon_tiger"
    public static let limitUp = "limit_up"
    public static let sector = "sector"
    public static let announcements = "announcements"
    public static let sentiment = "sentiment"
}
