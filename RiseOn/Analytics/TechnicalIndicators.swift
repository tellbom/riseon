import Foundation

/// Placeholder for the Swift rewrite of `technical_indicators.py`
/// (MA5/10/20/60 with `min_periods=1`, MACD 12/26/9, KDJ 9/3/3, BOLL 20/2,
/// latest signals).
///
/// Implemented in task.md S6.1-S6.2. Pure function, no I/O — see `CLAUDE.md` §"网络 I/O
/// 只允许出现在 QuoteProvider 与 LLMService". Left empty for now so the `Analytics/`
/// group compiles.
///
/// DECIDED (plan.md §0.5-2/§0.5-6, no longer open): RSI here must NOT be the
/// simple `rolling().mean()` version — `RuleScoreEngine` needs Wilder's EMA
/// instead (see `RiseOn_Analytics_RuleScore.swift`/S7). This type's own MA
/// (min_periods=1) must also stay independent from `RuleScoreEngine`'s MA
/// (full-window, MA60 falls back to MA20 under 60 bars) — do not merge the
/// two into one shared MA/RSI implementation.
public enum TechnicalIndicators {}
