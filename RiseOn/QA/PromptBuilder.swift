import Foundation

/// Assembles `(system, user)` prompts from a stock's `ContextPack` + rule
/// score + the static strategy blueprint + chat history + the current
/// question (task.md S9.1-S9.2, plan.md §9).
///
/// Pure function, no I/O, no LLM calls — those are `LLMService`'s job (S10).
public enum PromptBuilder {

    public struct Result: Equatable, Sendable {
        public var system: String
        public var user: String
    }

    /// Knobs that change how the prompt is phrased without changing the data.
    public struct Options: Equatable, Sendable {
        /// When the configured model can search the web (a search-augmented
        /// model, or the `web_search` tool round), the system prompt switches
        /// the news/公告/舆情 dimensions from "本地不支持，不得编造" to "本地
        /// 没有，但你可以联网检索最新信息并注明来源与时间". Off by default so
        /// the strict offline behavior (and every existing call site) is
        /// unchanged.
        public var webSearchEnabled: Bool

        public init(webSearchEnabled: Bool = false) {
            self.webSearchEnabled = webSearchEnabled
        }
    }

    /// - Parameters:
    ///   - pack: this stock's `ContextPack` (S8) — its `blocks` are rendered
    ///     with each one's real status, so `not_supported` blocks show up
    ///     explicitly as "本地不支持" rather than being silently omitted.
    ///   - ruleScore: separate from what's already summarized in `pack`'s
    ///     `technical`/`levels` blocks — used here specifically for its
    ///     human-readable reasoning strings (`signalReasons`/`riskFactors`),
    ///     which are worth surfacing verbatim rather than re-deriving from
    ///     the numeric fields already in the pack.
    ///   - history: prior turns in this stock's isolated `ChatThread`
    ///     (S11 owns truncation/summarization; this just renders whatever
    ///     it's handed).
    ///   - question: the user's current question.
    ///   - options: phrasing knobs (see `Options`).
    public static func build(
        pack: ContextPack,
        ruleScore: RuleScore?,
        history: [ChatMessage],
        question: String,
        options: Options = Options()
    ) -> Result {
        Result(
            system: systemPrompt(options: options),
            user: buildUserPrompt(pack: pack, ruleScore: ruleScore, history: history, question: question)
        )
    }

    // MARK: - System prompt (S9.2 + short-term analyst framework)

    /// Upgraded from the MVP's bare "只基于数据、别编造、给买卖点" into an
    /// explicit **短线分析框架**: a persona, a three-dimension synthesis
    /// method (资金面/情绪面/技术面), recency priority, conflict handling, and
    /// a hard line between rule data and the model's own inference — so the
    /// newly-injected factor data (资金流/龙虎榜/情绪…) is actually reasoned
    /// over, not just echoed.
    public static func systemPrompt(options: Options) -> String {
        var lines = [
            "你是一名专注 A 股短线（1–10 个交易日）的量化分析助手，服务对象是这只股票的持有者/潜在买家。你会拿到本地算好的行情、技术指标、规则评分、资金面、龙虎榜、涨跌停、板块热度、情绪面等结构化数据。",
            "",
            "分析框架（务必按此组织回答，而不是罗列数据）：",
            "1. 资金面优先：主力净流入方向与连续性、超大单/大单结构、龙虎榜净买卖、板块资金热度——这是短线最重要的驱动。",
            "2. 情绪面校验：涨跌停与连板、换手率、量比、情绪热度档位，判断资金是否有持续性、是否过热。",
            "3. 技术面定位：结合趋势、均线多空、MACD/RSI、支撑/阻力位，给出当前所处位置与关键价位。",
            "4. 三维交叉：优先采信最近 1–3 日的信号；当资金面、情绪面、技术面互相矛盾时，明确指出分歧并说明你更看重哪一维及理由，不要和稀泥。",
            "",
            "硬性规则：",
            "- 只使用本轮提供的数据作答，区分“规则引擎给出的客观数据”与“你自己的推断”，推断要说明依据，不得把猜测当作数据陈述。",
            "- 数据块被标注为“本地不支持”的（如筹码分布），本地拿不到；不得编造、不得用其它数据臆测替代。",
            "- 数据块状态是“拉取失败/已过期/部分可用”等非“可用”状态时，要如实告知该维度当前有局限、可能不完整或不是最新的，不能当作完整可靠的数据使用。",
            "- 必须向用户声明数据快照时间与数据质量等级；若整体质量是 limited 或 poor，或存在 warnings，要明确提示数据可能过期或不完整，让用户自行判断是否刷新。",
            "- 结合 `levels` 块的支撑/阻力位与技术指标，给出结构化买卖点：ideal_buy（理想买入价）、secondary_buy（次选买入价）、stop_loss（止损价）、take_profit（止盈价），并说明依据；若你没有更合适的止损判断，可直接采用 `levels` 块第一个支撑位作为保守止损参考。",
            "- 所有回答仅供参考、不构成投资建议，不承诺收益，不规避亏损风险。",
        ]

        if options.webSearchEnabled {
            lines.append("")
            lines.append("联网补充（你具备联网检索能力）：本地不支持新闻/公告/舆情等维度，但你可以主动检索该股票的最新新闻、公告与市场舆情来补充判断；引用检索到的信息时必须注明来源与时间，明确区分“检索所得”与“本地数据”，且不得让检索内容覆盖本地已给出的行情/资金/技术数据。")
        } else {
            lines.append("")
            lines.append("- 新闻/公告/舆情等维度本地不支持、也无联网能力，若用户问及，如实说明拿不到，不要编造。")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - User prompt

    private static func buildUserPrompt(
        pack: ContextPack,
        ruleScore: RuleScore?,
        history: [ChatMessage],
        question: String
    ) -> String {
        var sections: [String] = [renderSubject(pack.subject)]

        sections.append("## 数据质量\n" + renderDataQuality(pack.dataQuality))
        sections.append("## 数据明细\n" + renderBlocks(pack))

        if let ruleScore, hasReasoning(ruleScore) {
            sections.append("## 规则引擎评分依据\n" + renderRuleScoreReasoning(ruleScore))
        }

        sections.append(MarketStrategyBlueprint.promptBlock())

        if !history.isEmpty {
            sections.append("## 历史对话\n" + renderHistory(history))
        }

        sections.append("## 当前问题\n\(question)")

        return sections.joined(separator: "\n\n")
    }

    private static func renderSubject(_ subject: ContextPackSubject) -> String {
        """
        ## 股票信息
        代码：\(subject.code)
        名称：\(subject.stockName ?? "未知")
        市场：\(subject.market ?? "未知")
        """
    }

    private static func renderDataQuality(_ quality: DataQuality) -> String {
        var lines: [String] = []
        if let score = quality.overallScore, let level = quality.level {
            lines.append("总体评分：\(score)/100（\(level)）")
        }
        if !quality.limitations.isEmpty {
            lines.append("已知限制：" + quality.limitations.joined(separator: "；"))
        }
        if !quality.warnings.isEmpty {
            lines.append("提示：" + quality.warnings.joined(separator: "；"))
        }
        return lines.isEmpty ? "（无数据质量信息）" : lines.joined(separator: "\n")
    }

    /// Fixed, stable rendering order — not dictionary iteration order,
    /// which Swift doesn't guarantee call-to-call.
    private static let blockOrder = [
        ContextBlockKey.quote, ContextBlockKey.dailyBars, ContextBlockKey.technical,
        ContextBlockKey.factors, ContextBlockKey.levels,
        ContextBlockKey.valuation, ContextBlockKey.capitalFlow, ContextBlockKey.dragonTiger,
        ContextBlockKey.limitUp, ContextBlockKey.sector, ContextBlockKey.sentiment,
        ContextBlockKey.fundamentals, ContextBlockKey.announcements,
        ContextBlockKey.chip, ContextBlockKey.news, ContextBlockKey.events,
    ]

    private static let blockDisplayNames: [String: String] = [
        ContextBlockKey.quote: "实时行情",
        ContextBlockKey.dailyBars: "日线数据",
        ContextBlockKey.technical: "技术指标",
        ContextBlockKey.factors: "因子窗口",
        ContextBlockKey.levels: "支撑/阻力位",
        ContextBlockKey.chip: "筹码分布",
        ContextBlockKey.fundamentals: "基本面",
        ContextBlockKey.news: "新闻/情报",
        ContextBlockKey.capitalFlow: "资金流",
        ContextBlockKey.events: "事件日历",
        ContextBlockKey.valuation: "估值/交易面",
        ContextBlockKey.dragonTiger: "龙虎榜",
        ContextBlockKey.limitUp: "涨跌停",
        ContextBlockKey.sector: "行业板块",
        ContextBlockKey.announcements: "公告",
        ContextBlockKey.sentiment: "情绪面",
    ]

    /// Chinese label for every `ContextFieldStatus`, not just
    /// `.notSupported` (task.md S15.1: any degraded status — a failed
    /// fetch, a stale/partial block — must be stated honestly, not just
    /// the "not supported" case).
    private static let statusDisplayNames: [ContextFieldStatus: String] = [
        .available: "可用",
        .missing: "缺失",
        .notSupported: "本地不支持",
        .fallback: "已降级",
        .stale: "已过期",
        .estimated: "估算值",
        .partial: "部分可用",
        .fetchFailed: "拉取失败",
    ]

    private static func renderBlocks(_ pack: ContextPack) -> String {
        blockOrder.compactMap { key -> String? in
            guard let block = pack.blocks[key] else { return nil }
            let title = blockDisplayNames[key] ?? key
            let statusLabel = statusDisplayNames[block.status] ?? block.status.rawValue

            // Explicit, unmissable "本地不支持" line -- task.md S9.1's own
            // verification point is that this literal phrase shows up for
            // unsupported blocks, not just an implied absence. Other
            // degraded statuses (fetch_failed/stale/partial/...) get the
            // same treatment via `statusDisplayNames` below, just without
            // skipping the item details (those are still worth showing).
            if block.status == .notSupported {
                return "### \(title)\n状态：\(statusLabel)"
            }

            var lines = ["### \(title)", "状态：\(statusLabel)"]
            let sortedKeys = block.items.keys.sorted {
                let lhs = PromptFieldFormatting.sortIndex($0)
                let rhs = PromptFieldFormatting.sortIndex($1)
                return lhs == rhs ? $0 < $1 : lhs < rhs
            }
            for itemKey in sortedKeys {
                guard let item = block.items[itemKey] else { continue }
                if let value = item.value {
                    lines.append(PromptFieldFormatting.line(key: itemKey, value: value))
                } else if let reason = item.missingReason {
                    let label = PromptFieldFormatting.specs[itemKey]?.label ?? itemKey
                    lines.append("- \(label)：缺失（\(reason)）")
                }
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private static func hasReasoning(_ ruleScore: RuleScore) -> Bool {
        !ruleScore.signalReasons.isEmpty || !ruleScore.riskFactors.isEmpty
    }

    private static func renderRuleScoreReasoning(_ ruleScore: RuleScore) -> String {
        var lines: [String] = []
        if !ruleScore.signalReasons.isEmpty {
            lines.append("支持因素：" + ruleScore.signalReasons.joined(separator: "；"))
        }
        if !ruleScore.riskFactors.isEmpty {
            lines.append("风险因素：" + ruleScore.riskFactors.joined(separator: "；"))
        }
        return lines.joined(separator: "\n")
    }

    private static func renderHistory(_ history: [ChatMessage]) -> String {
        history.map { message in
            let roleLabel = message.role == .user ? "用户" : "助手"
            return "\(roleLabel)：\(message.content)"
        }.joined(separator: "\n")
    }
}
