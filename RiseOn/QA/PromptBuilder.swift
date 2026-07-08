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
    public static func build(
        pack: ContextPack,
        ruleScore: RuleScore?,
        history: [ChatMessage],
        question: String
    ) -> Result {
        Result(system: systemPrompt, user: buildUserPrompt(pack: pack, ruleScore: ruleScore, history: history, question: question))
    }

    // MARK: - System prompt (S9.2)

    /// Mirrors the spirit of `chat_context.py::SUMMARY_SYSTEM_PROMPT`'s
    /// "只总结已有内容，不新增行情/新闻/建议" discipline, applied to Q&A
    /// rather than summarization, plus S9.1's sniper-points instruction
    /// (plan.md §0.5-1: this app never computes `ideal_buy`/`secondary_buy`/
    /// `take_profit` itself — that's the LLM's job, guided by the `levels`
    /// block).
    public static let systemPrompt = """
    你是一个本地个股问答助手，只能基于本轮消息里提供的数据回答问题，服务对象是这只股票的持有者/潜在买家。

    硬性规则：
    - 只使用本轮提供的数据作答，不得编造、猜测数据之外的行情、新闻、财务数据或市场消息。
    - 如果某个数据块被标注为"本地不支持"（如新闻、筹码等），必须如实告知用户这类信息本地拿不到，不能假装拥有、也不能用其他数据臆测替代。
    - 如果某个数据块状态是"拉取失败""已过期""部分可用"等非"可用"状态（不只是"本地不支持"），同样要如实告知用户这部分数据当前有局限、可能不完整或不是最新的，不能当作完整可靠的数据使用。
    - 必须向用户声明数据快照时间与数据质量等级；如果整体质量是 limited 或 poor，或者存在 warnings，需要明确提示用户数据可能过期或不完整，让用户自行判断是否需要刷新。
    - 结合 `levels` 块给出的支撑位/阻力位与技术指标数据，给出结构化的买卖点建议：ideal_buy（理想买入价）、secondary_buy（次选买入价）、stop_loss（止损价）、take_profit（止盈价），并说明依据。若你自己没有更合适的止损位判断，可以直接参考 `levels` 块里的第一个支撑位作为保守止损参考。
    - 所有回答仅供参考、不构成投资建议，不承诺收益，不规避亏损风险。
    """

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
            for itemKey in block.items.keys.sorted() {
                guard let item = block.items[itemKey] else { continue }
                if let value = item.value {
                    lines.append("- \(itemKey)：\(value.promptRendering)")
                } else if let reason = item.missingReason {
                    lines.append("- \(itemKey)：缺失（\(reason)）")
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

/// Compact, human/LLM-readable rendering for prompt text -- deliberately
/// **not** JSON syntax (no quoted keys, no braces-as-punctuation noise).
/// Kept private to this file since it's a prompt-formatting concern, not a
/// general-purpose `JSONValue` API.
extension JSONValue {
    fileprivate var promptRendering: String {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        case .array(let values):
            return "[" + values.map(\.promptRendering).joined(separator: ", ") + "]"
        case .object(let values):
            return "{" + values.keys.sorted().map { "\($0): \(values[$0]!.promptRendering)" }.joined(separator: ", ") + "}"
        }
    }
}
