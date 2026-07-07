import XCTest
@testable import RiseOn

/// Covers task.md S9.1 (missing blocks labeled "本地不支持" in the prompt;
/// prompt instructs the LLM to produce sniper_points) and S9.2 (system
/// prompt requires answering only from given data, no fabrication, declares
/// data staleness). The actual "LLM doesn't fabricate news" behavior
/// (S9.2's verification point) needs a real LLM call and human review —
/// not something a unit test can check — so these tests instead verify the
/// **precondition**: that the prompt itself carries the right instructions
/// and labels for that behavior to be possible.
final class PromptBuilderTests: XCTestCase {

    private func makePack(newsStatus: ContextFieldStatus = .notSupported) -> ContextPack {
        ContextPack(
            subject: ContextPackSubject(code: "600519", stockName: "贵州茅台", market: "sh"),
            blocks: [
                ContextBlockKey.quote: ContextBlock(
                    status: .available,
                    items: ["price": ContextItem(status: .available, value: .double(1700.5))]
                ),
                ContextBlockKey.dailyBars: ContextBlock(status: .available, items: ["count": ContextItem(status: .available, value: .int(120))]),
                ContextBlockKey.technical: ContextBlock(status: .available, items: ["signal_score": ContextItem(status: .available, value: .int(71))]),
                ContextBlockKey.factors: ContextBlock(status: .partial),
                ContextBlockKey.levels: ContextBlock(
                    status: .available,
                    items: ["support_levels": ContextItem(status: .available, value: .doubleArray([1650.0, 1600.0]))]
                ),
                ContextBlockKey.chip: ContextBlock(status: .notSupported, items: ["value": ContextItem(status: .notSupported, missingReason: "端上无法直连筹码分布数据源")]),
                ContextBlockKey.fundamentals: ContextBlock(status: .notSupported, items: ["value": ContextItem(status: .notSupported, missingReason: "端上无法直连基本面数据源")]),
                ContextBlockKey.news: ContextBlock(status: newsStatus, items: ["value": ContextItem(status: newsStatus, missingReason: "端上不支持新闻/情报联网检索")]),
                ContextBlockKey.capitalFlow: ContextBlock(status: .notSupported),
                ContextBlockKey.events: ContextBlock(status: .notSupported),
            ],
            dataQuality: DataQuality(
                overallScore: 80,
                level: "usable",
                blockScores: ["quote": 100],
                limitations: ["technical: partial"],
                warnings: [ContextPackWarningKey.intradayVolumeOverlaySkipped]
            )
        )
    }

    private func makeRuleScore() -> RuleScore {
        var score = RuleScore(code: "600519", signalScore: 71)
        score.signalReasons = ["✅ 多头排列，顺势做多", "✅ MA5支撑有效"]
        score.riskFactors = ["⚠️ RSI超买(85.0>70)，短期回调风险高"]
        return score
    }

    // MARK: - S9.1: missing blocks labeled "本地不支持"

    func test_notSupportedBlocks_labeledLocallyUnsupportedInUserPrompt() {
        let result = PromptBuilder.build(pack: makePack(), ruleScore: nil, history: [], question: "现在能买吗？")

        // Each not_supported block section explicitly says so.
        XCTAssertTrue(result.user.contains("新闻/情报\n状态：本地不支持"))
        XCTAssertTrue(result.user.contains("基本面\n状态：本地不支持"))
        XCTAssertTrue(result.user.contains("筹码分布\n状态：本地不支持"))
        XCTAssertTrue(result.user.contains("资金流\n状态：本地不支持"))
        XCTAssertTrue(result.user.contains("事件日历\n状态：本地不支持"))
    }

    func test_availableBlocks_showActualStatusNotUnsupported() {
        let result = PromptBuilder.build(pack: makePack(), ruleScore: nil, history: [], question: "?")
        XCTAssertTrue(result.user.contains("实时行情\n状态：可用"))
        XCTAssertTrue(result.user.contains("因子窗口\n状态：部分可用"))
        XCTAssertFalse(result.user.contains("实时行情\n状态：本地不支持"))
    }

    // MARK: - S9.1: sniper_points instruction present

    func test_systemPrompt_instructsProducingSniperPoints() {
        let system = PromptBuilder.build(pack: makePack(), ruleScore: nil, history: [], question: "?").system
        XCTAssertTrue(system.contains("ideal_buy"))
        XCTAssertTrue(system.contains("secondary_buy"))
        XCTAssertTrue(system.contains("stop_loss"))
        XCTAssertTrue(system.contains("take_profit"))
        XCTAssertTrue(system.contains("levels"), "must tell the LLM to ground sniper points in the levels block")
    }

    // MARK: - S9.2: no fabrication / staleness declaration

    func test_systemPrompt_forbidsFabricatingDataNotProvided() {
        let system = PromptBuilder.build(pack: makePack(), ruleScore: nil, history: [], question: "?").system
        XCTAssertTrue(system.contains("不得编造"))
        XCTAssertTrue(system.contains("本地不支持"))
    }

    func test_systemPrompt_requiresDeclaringDataQualityAndStaleness() {
        let system = PromptBuilder.build(pack: makePack(), ruleScore: nil, history: [], question: "?").system
        XCTAssertTrue(system.contains("数据快照时间"))
        XCTAssertTrue(system.contains("数据质量等级"))
        XCTAssertTrue(system.contains("过期"))
    }

    func test_systemPrompt_disclaimsInvestmentAdvice() {
        let system = PromptBuilder.build(pack: makePack(), ruleScore: nil, history: [], question: "?").system
        XCTAssertTrue(system.contains("不构成投资建议"))
    }

    // MARK: - User prompt content assembly

    func test_userPrompt_includesSubjectDataQualityAndQuestion() {
        let result = PromptBuilder.build(pack: makePack(), ruleScore: nil, history: [], question: "现在能买吗？")
        XCTAssertTrue(result.user.contains("600519"))
        XCTAssertTrue(result.user.contains("贵州茅台"))
        XCTAssertTrue(result.user.contains("80/100"))
        XCTAssertTrue(result.user.contains("usable"))
        XCTAssertTrue(result.user.contains("technical: partial"), "limitations must surface")
        XCTAssertTrue(result.user.contains(ContextPackWarningKey.intradayVolumeOverlaySkipped))
        XCTAssertTrue(result.user.contains("现在能买吗？"))
    }

    func test_userPrompt_includesRuleScoreReasoningWhenPresent() {
        let result = PromptBuilder.build(pack: makePack(), ruleScore: makeRuleScore(), history: [], question: "?")
        XCTAssertTrue(result.user.contains("多头排列，顺势做多"))
        XCTAssertTrue(result.user.contains("RSI超买"))
    }

    func test_userPrompt_omitsReasoningSectionWhenRuleScoreHasNone() {
        var empty = RuleScore(code: "600519")
        empty.signalReasons = []
        empty.riskFactors = []
        let result = PromptBuilder.build(pack: makePack(), ruleScore: empty, history: [], question: "?")
        XCTAssertFalse(result.user.contains("规则引擎评分依据"))
    }

    func test_userPrompt_omitsHistorySectionWhenEmpty() {
        let result = PromptBuilder.build(pack: makePack(), ruleScore: nil, history: [], question: "?")
        XCTAssertFalse(result.user.contains("历史对话"))
    }

    func test_userPrompt_includesHistoryWhenPresent() {
        let history = [
            ChatMessage(role: .user, content: "上次问的问题"),
            ChatMessage(role: .assistant, content: "上次的回答"),
        ]
        let result = PromptBuilder.build(pack: makePack(), ruleScore: nil, history: history, question: "新问题")
        XCTAssertTrue(result.user.contains("历史对话"))
        XCTAssertTrue(result.user.contains("用户：上次问的问题"))
        XCTAssertTrue(result.user.contains("助手：上次的回答"))
    }

    // MARK: - Blueprint: principles/action framework in, dimensions out

    func test_userPrompt_includesBlueprintPrinciplesAndActionFramework() {
        let result = PromptBuilder.build(pack: makePack(), ruleScore: nil, history: [], question: "?")
        XCTAssertTrue(result.user.contains("先看指数方向，再看量能结构，最后看板块持续性。"))
        XCTAssertTrue(result.user.contains("进攻：指数共振上行"))
    }

    func test_userPrompt_excludesIndexLevelDimensionsContent() {
        // "涨跌家数" and "板块轮动" checkpoints are `dimensions` content in
        // market_strategy.py::CN_BLUEPRINT -- deliberately not ported
        // (index/sector-recap content, not applicable per-stock).
        let result = PromptBuilder.build(pack: makePack(), ruleScore: nil, history: [], question: "?")
        XCTAssertFalse(result.user.contains("涨跌家数"))
        XCTAssertFalse(result.user.contains("Analysis Dimensions"))
    }

    // MARK: - JSONValue rendering inside the prompt

    func test_arrayValues_renderReadably_notAsJSONSyntax() {
        let result = PromptBuilder.build(pack: makePack(), ruleScore: nil, history: [], question: "?")
        // support_levels was [1650.0, 1600.0] -- should read like a plain list.
        XCTAssertTrue(result.user.contains("[1650.0, 1600.0]"))
    }
}
