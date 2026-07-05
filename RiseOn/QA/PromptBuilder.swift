import Foundation

/// Placeholder for assembling `(systemPrompt, userPrompt)` from
/// `ContextPack (incl. levels block) + RuleScore + MarketStrategyBlueprint text
/// + history + question`, explicitly labeling unsupported blocks
/// (news/fundamentals/etc.) as "本地不支持" so the LLM doesn't fabricate data.
///
/// Per plan.md §0.5-1/§9: the prompt must explicitly instruct the LLM to
/// combine the `levels` (support/resistance) block with technical data to
/// produce `sniper_points` (`ideal_buy`/`secondary_buy`/`stop_loss`/
/// `take_profit`) — this app does not compute those with a rule engine.
///
/// Implemented in task.md S9.1-S9.2. Left empty for now so the `QA/` group
/// compiles.
public enum PromptBuilder {}
