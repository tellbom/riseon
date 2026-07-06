import Foundation

/// Static prompt text ported from `src/core/market_strategy.py::CN_BLUEPRINT`
/// (task.md S9.1, plan.md §2.3/§8) — **only** `principles` and
/// `action_framework`. `dimensions` is deliberately left out: it's written
/// for a whole-market/sector recap (涨跌家数, 板块轮动, 领涨板块...), not a
/// single stock, and would read as a non sequitur bolted onto a per-stock
/// Q&A prompt. Only the CN blueprint is ported — this app is A-share only
/// (per its own scope), so `US_BLUEPRINT`/`HK_BLUEPRINT`/etc. never apply.
public enum MarketStrategyBlueprint {
    public static let principles: [String] = [
        "先看指数方向，再看量能结构，最后看板块持续性。",
        "结论必须映射到仓位、节奏与风险控制动作。",
        "判断使用当日数据与近3日新闻，不臆测未验证信息。",
    ]

    public static let actionFramework: [String] = [
        "进攻：指数共振上行 + 成交额放大 + 主线强化。",
        "均衡：指数分化或缩量震荡，控制仓位并等待确认。",
        "防守：指数转弱 + 领跌扩散，优先风控与减仓。",
    ]

    /// Renders like `MarketStrategyBlueprint.to_prompt_block()` on the
    /// Python side, minus the `### Analysis Dimensions` section.
    public static func promptBlock() -> String {
        let principlesText = principles.map { "- \($0)" }.joined(separator: "\n")
        let actionText = actionFramework.map { "- \($0)" }.joined(separator: "\n")
        return """
        ## 策略框架参考：A股市场复盘纪律（节选自三段式复盘策略，仅通用交易纪律，省略大盘维度分析）
        以下是通用的交易纪律原则，请在给出个股操作建议时作为参考背景，不要照搬其中面向大盘的表述。

        ### 原则
        \(principlesText)

        ### 行动框架
        \(actionText)
        """
    }
}
