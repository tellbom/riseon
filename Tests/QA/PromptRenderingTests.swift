import XCTest
@testable import RiseOn

/// Covers the prompt-rendering upgrade: unit/口径-aware field formatting
/// (the fix for "数据平铺太粗暴") and the web-search system-prompt clause.
final class PromptRenderingTests: XCTestCase {

    // MARK: - Field formatting

    func test_money_autoScalesAndSigns() {
        XCTAssertEqual(PromptFieldFormatting.line(key: "main_net_inflow", value: .double(123_500_000)), "- 主力净流入：+1.24亿元")
        XCTAssertEqual(PromptFieldFormatting.line(key: "main_net_inflow", value: .double(-45_000)), "- 主力净流入：-4.5万元")
        XCTAssertEqual(PromptFieldFormatting.line(key: "main_net_inflow", value: .double(800)), "- 主力净流入：+800元")
    }

    func test_percentRatioScoreAndBool() {
        XCTAssertEqual(PromptFieldFormatting.line(key: "turnover_rate", value: .double(3.2)), "- 换手率：3.2%")
        XCTAssertEqual(PromptFieldFormatting.line(key: "change_pct", value: .double(-1.5)), "- 板块涨跌幅：-1.5%")
        XCTAssertEqual(PromptFieldFormatting.line(key: "volume_ratio", value: .double(1.3)), "- 量比：1.3")
        XCTAssertEqual(PromptFieldFormatting.line(key: "signal_score", value: .int(71)), "- 规则评分：71/100")
        XCTAssertEqual(PromptFieldFormatting.line(key: "is_limit_up", value: .bool(true)), "- 今日涨停：是")
        XCTAssertEqual(PromptFieldFormatting.line(key: "total_market_cap", value: .double(2000)), "- 总市值：2000亿元")
    }

    func test_priceArray_rendersLevels() {
        XCTAssertEqual(
            PromptFieldFormatting.line(key: "support_levels", value: .doubleArray([1650, 1600.5])),
            "- 支撑位：1650 / 1600.5"
        )
    }

    func test_unknownKey_fallsBackToRaw() {
        XCTAssertEqual(PromptFieldFormatting.line(key: "brand_new_field", value: .string("x")), "- brand_new_field：x")
    }

    // MARK: - System prompt web clause

    func test_systemPrompt_default_isOfflineStrict() {
        let system = PromptBuilder.systemPrompt(options: .init(webSearchEnabled: false))
        XCTAssertTrue(system.contains("无联网能力"))
        XCTAssertTrue(system.contains("不得编造"))
        // required legacy clauses still present
        XCTAssertTrue(system.contains("ideal_buy"))
        XCTAssertTrue(system.contains("数据快照时间"))
    }

    func test_systemPrompt_webEnabled_permitsRetrievalWithCitation() {
        let system = PromptBuilder.systemPrompt(options: .init(webSearchEnabled: true))
        XCTAssertTrue(system.contains("联网检索"))
        XCTAssertTrue(system.contains("注明信息来源机构与发布时间"))
    }

    /// S19 T2: retrieved content must be treated as a 情绪面/舆情因子 that's
    /// cross-referenced against local 资金面/技术面 data, not a standalone
    /// answer -- and local data always wins on conflict.
    func test_systemPrompt_webEnabled_treatsRetrievalAsSentimentFactorRequiringCrossReference() {
        let system = PromptBuilder.systemPrompt(options: .init(webSearchEnabled: true))
        XCTAssertTrue(system.contains("情绪面/舆情因子"))
        XCTAssertTrue(system.contains("交叉验证"))
        XCTAssertTrue(system.contains("以本地数据为准"))
    }

    func test_build_passesWebOptionIntoSystem() {
        let pack = ContextPack(subject: ContextPackSubject(code: "600519"))
        let web = PromptBuilder.build(pack: pack, ruleScore: nil, history: [], question: "?", options: .init(webSearchEnabled: true))
        XCTAssertTrue(web.system.contains("联网检索"))
        let offline = PromptBuilder.build(pack: pack, ruleScore: nil, history: [], question: "?")
        XCTAssertFalse(offline.system.contains("联网检索"))
    }
}
