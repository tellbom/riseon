import XCTest
@testable import RiseOn

/// Covers task.md S15.1: a failed data-fetch step gets `fetch_failed`
/// (distinct from `missing`, which means "never had a source for this at
/// all"), and the workspace can still reach a usable, honestly-labeled
/// state ("部分就绪" / `.partial`) rather than getting stuck.
final class ContextPackBuilderFetchFailedTests: XCTestCase {

    // MARK: - quote

    func test_quote_missingWithoutFetchAttempt_isMissing() {
        let pack = ContextPackBuilder.build(.init(subject: ContextPackSubject(code: "600519"), quote: nil, quoteFetchFailed: false))
        XCTAssertEqual(pack.blocks[ContextBlockKey.quote]?.status, .missing)
    }

    func test_quote_failedFetch_isFetchFailedNotMissing() {
        let pack = ContextPackBuilder.build(.init(subject: ContextPackSubject(code: "600519"), quote: nil, quoteFetchFailed: true))
        XCTAssertEqual(pack.blocks[ContextBlockKey.quote]?.status, .fetchFailed)
        XCTAssertEqual(pack.blocks[ContextBlockKey.quote]?.items["quote"]?.missingReason, "拉取实时行情失败")
    }

    // MARK: - daily_bars (and its cascade into technical/factors/levels)

    func test_dailyBars_failedFetch_cascadesToFetchFailedAcrossDerivedBlocks() {
        let pack = ContextPackBuilder.build(.init(
            subject: ContextPackSubject(code: "600519"),
            dailyBars: [],
            dailyBarsFetchFailed: true
        ))

        XCTAssertEqual(pack.blocks[ContextBlockKey.dailyBars]?.status, .fetchFailed)
        XCTAssertEqual(pack.blocks[ContextBlockKey.technical]?.status, .fetchFailed)
        XCTAssertEqual(pack.blocks[ContextBlockKey.factors]?.status, .fetchFailed)
        XCTAssertEqual(pack.blocks[ContextBlockKey.levels]?.status, .fetchFailed)
    }

    func test_dailyBars_neverAttempted_staysMissingNotFetchFailed() {
        let pack = ContextPackBuilder.build(.init(
            subject: ContextPackSubject(code: "600519"),
            dailyBars: [],
            dailyBarsFetchFailed: false
        ))

        XCTAssertEqual(pack.blocks[ContextBlockKey.dailyBars]?.status, .missing)
        XCTAssertEqual(pack.blocks[ContextBlockKey.technical]?.status, .missing)
        XCTAssertEqual(pack.blocks[ContextBlockKey.factors]?.status, .missing)
        XCTAssertEqual(pack.blocks[ContextBlockKey.levels]?.status, .missing)
    }

    func test_levels_tooFewBarsButPresent_isMissingNotFetchFailed() {
        // Bars exist (fetch succeeded) but there just aren't 20 of them yet
        // -- this is a "not enough history", not a fetch failure, even if
        // `dailyBarsFetchFailed` were somehow left true by mistake upstream.
        let bars = (0..<10).map { i in DailyBar(date: "d\(i)", open: 10, close: 10, high: 10.1, low: 9.9, volume: 100) }
        let pack = ContextPackBuilder.build(.init(
            subject: ContextPackSubject(code: "600519"),
            dailyBars: bars,
            dailyBarsFetchFailed: true // deliberately inconsistent input, to prove bars.isEmpty is what actually gates this
        ))
        XCTAssertEqual(pack.blocks[ContextBlockKey.levels]?.status, .missing)
    }

    // MARK: - Data quality still degrades sensibly, doesn't block readiness

    func test_dataQuality_fetchFailedScoresLowerThanMissing() {
        // fetch_failed(25) < missing(35) in the weight table -- a known,
        // active failure is treated as *worse* than "never had it".
        let failedPack = ContextPackBuilder.build(.init(subject: ContextPackSubject(code: "600519"), dailyBars: [], quote: nil, quoteFetchFailed: true, dailyBarsFetchFailed: true))
        let missingPack = ContextPackBuilder.build(.init(subject: ContextPackSubject(code: "600519"), dailyBars: [], quote: nil, quoteFetchFailed: false, dailyBarsFetchFailed: false))

        XCTAssertLessThan(failedPack.dataQuality.overallScore!, missingPack.dataQuality.overallScore!)
    }

    func test_offlineInitialization_stillReachesPartialReadiness() throws {
        // task.md S15.1's actual scenario: everything that requires network
        // failed, but the workspace must still reach a usable, honestly-
        // labeled state rather than getting stuck.
        let pack = ContextPackBuilder.build(.init(
            subject: ContextPackSubject(code: "600519", stockName: "贵州茅台", market: "sh"),
            dailyBars: [],
            quote: nil,
            quoteFetchFailed: true,
            dailyBarsFetchFailed: true
        ))

        // Quality is poor (everything core is fetch_failed), but not nil --
        // there's still a defined, honest quality assessment.
        XCTAssertEqual(pack.dataQuality.level, "poor")
        XCTAssertNotNil(pack.dataQuality.overallScore)

        // The workspace itself must still be able to move on to a usable
        // (if degraded) ready state -- `applyRefreshedPack` maps
        // non-good/usable levels to `.partial`, not stuck in `.initializing`.
        var workspace = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh")
        try workspace.transition(to: .initializing)
        try workspace.applyRefreshedPack(pack, ruleScore: nil, snapshotDate: Date(), source: "tencent")
        XCTAssertEqual(workspace.state, .partial, "断网初始化仍能进入部分就绪")

        // And PromptBuilder must render the failures honestly, not silently.
        let prompt = PromptBuilder.build(pack: pack, ruleScore: nil, history: [], question: "现在能买吗？")
        XCTAssertTrue(prompt.user.contains("拉取失败"), "fetch_failed blocks must be labeled honestly, not hidden")
    }

    func test_limitations_includeFetchFailedCoreBlocks() {
        let pack = ContextPackBuilder.build(.init(subject: ContextPackSubject(code: "600519"), dailyBars: [], quote: nil, quoteFetchFailed: true, dailyBarsFetchFailed: true))
        XCTAssertTrue(pack.dataQuality.limitations.contains("quote: fetch_failed"))
        XCTAssertTrue(pack.dataQuality.limitations.contains("daily_bars: fetch_failed"))
        XCTAssertTrue(pack.dataQuality.limitations.contains("technical: fetch_failed"))
    }
}
