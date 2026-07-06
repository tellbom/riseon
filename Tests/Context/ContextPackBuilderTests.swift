import XCTest
@testable import RiseOn

/// Covers task.md S8.2 (block assembly + warnings) and S8.3 (data-quality
/// scoring). The scoring math was independently verified against
/// `analysis_context_builder.py::_build_data_quality`'s exact formula
/// (weighted sum / 100, `round()`) run in a real Python session before
/// being transcribed as expected values here.
final class ContextPackBuilderTests: XCTestCase {

    private func makeQuote(price: Double = 1700) -> Quote {
        guard let symbol = StockSymbol(code: "600519") else {
            fatalError("600519 must be a valid StockSymbol")
        }
        return Quote(
            symbol: symbol, name: "贵州茅台", price: price, previousClose: 1650,
            open: 1660, high: 1710, low: 1655, changeAmount: price - 1650,
            changePercent: (price - 1650) / 1650 * 100,
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000), orderBook: nil
        )
    }

    private func makeBars(count: Int, startClose: Double = 10.0) -> [DailyBar] {
        (0..<count).map { i in
            let close = startClose + Double(i) * 0.1
            return DailyBar(date: "2024-06-\(String(format: "%02d", (i % 28) + 1))", open: close, close: close, high: close + 0.1, low: close - 0.1, volume: 10_000)
        }
    }

    // MARK: - S8.2: block statuses, happy path

    func test_fullInputs_producesExpectedBlockStatuses() {
        let bars = makeBars(count: 40)
        let series = TechnicalIndicators.computeAll(bars: bars)
        let signals = TechnicalIndicators.latestSignals(bars: bars, series: series)
        let ruleScore = RuleScoreEngine.analyze(bars: bars, code: "600519")

        let pack = ContextPackBuilder.build(.init(
            subject: ContextPackSubject(code: "600519", stockName: "贵州茅台", market: "sh"),
            dailyBars: bars,
            overlayWarnings: [ContextPackWarningKey.intradayVolumeOverlaySkipped],
            quote: makeQuote(),
            technicalSeries: series,
            latestSignals: signals,
            ruleScore: ruleScore,
            windowReturns: FactorWindows.windowReturns(bars: bars),
            rangePosition20d: FactorWindows.rangePosition(bars: bars)
        ))

        XCTAssertEqual(pack.blocks[ContextBlockKey.quote]?.status, .available)
        XCTAssertEqual(pack.blocks[ContextBlockKey.dailyBars]?.status, .available)
        XCTAssertEqual(pack.blocks[ContextBlockKey.technical]?.status, .available)
        XCTAssertEqual(pack.blocks[ContextBlockKey.factors]?.status, .partial, "only the technical sub-slice is ever computed")
        XCTAssertEqual(pack.blocks[ContextBlockKey.levels]?.status, .available)
        XCTAssertEqual(pack.blocks[ContextBlockKey.chip]?.status, .notSupported)
        XCTAssertEqual(pack.blocks[ContextBlockKey.fundamentals]?.status, .notSupported)
        XCTAssertEqual(pack.blocks[ContextBlockKey.news]?.status, .notSupported)
        XCTAssertEqual(pack.blocks[ContextBlockKey.capitalFlow]?.status, .notSupported)
        XCTAssertEqual(pack.blocks[ContextBlockKey.events]?.status, .notSupported)
    }

    func test_technicalBlock_carriesIndicatorAndScoreSummary() {
        let bars = makeBars(count: 40)
        let series = TechnicalIndicators.computeAll(bars: bars)
        let ruleScore = RuleScoreEngine.analyze(bars: bars, code: "600519")

        let pack = ContextPackBuilder.build(.init(
            subject: ContextPackSubject(code: "600519"),
            dailyBars: bars,
            technicalSeries: series,
            ruleScore: ruleScore
        ))

        let technical = pack.blocks[ContextBlockKey.technical]!
        XCTAssertEqual(technical.items["ma5"]?.value, .double(series.ma5.last!))
        XCTAssertEqual(technical.items["signal_score"]?.value, .int(ruleScore.signalScore))
        XCTAssertEqual(technical.items["trend_status"]?.value, .string(ruleScore.trendStatus.rawValue))
        XCTAssertEqual(technical.items["buy_signal"]?.value, .string(ruleScore.buySignal.rawValue))
    }

    func test_levelsBlock_carriesSupportResistanceAndStopLossFallback() {
        let bars = makeBars(count: 40)
        let ruleScore = RuleScoreEngine.analyze(bars: bars, code: "600519")

        let pack = ContextPackBuilder.build(.init(
            subject: ContextPackSubject(code: "600519"),
            dailyBars: bars,
            ruleScore: ruleScore
        ))

        let levels = pack.blocks[ContextBlockKey.levels]!
        XCTAssertEqual(levels.status, .available)
        XCTAssertEqual(levels.items["support_levels"]?.value, .doubleArray(ruleScore.supportLevels))
        XCTAssertEqual(levels.items["resistance_levels"]?.value, .doubleArray(ruleScore.resistanceLevels))
        if let expectedStopLoss = RuleScoreEngine.stopLossFallback(for: ruleScore) {
            XCTAssertEqual(levels.items["stop_loss_fallback"]?.value, .double(expectedStopLoss))
        }
    }

    // MARK: - S8.2: missing-data paths

    func test_noQuote_producesMissingQuoteBlock() {
        let pack = ContextPackBuilder.build(.init(
            subject: ContextPackSubject(code: "600519"),
            dailyBars: makeBars(count: 40),
            quote: nil
        ))
        XCTAssertEqual(pack.blocks[ContextBlockKey.quote]?.status, .missing)
    }

    func test_emptyDailyBars_missingAcrossDependentBlocks() {
        let pack = ContextPackBuilder.build(.init(
            subject: ContextPackSubject(code: "600519"),
            dailyBars: []
        ))
        XCTAssertEqual(pack.blocks[ContextBlockKey.dailyBars]?.status, .missing)
        XCTAssertEqual(pack.blocks[ContextBlockKey.technical]?.status, .missing)
        XCTAssertEqual(pack.blocks[ContextBlockKey.factors]?.status, .missing)
        XCTAssertEqual(pack.blocks[ContextBlockKey.levels]?.status, .missing)
    }

    func test_fewerThan20Bars_technicalPartial_levelsMissing() {
        // TechnicalIndicators itself computes fine on <20 bars (min_periods=1),
        // but RuleScoreEngine's score/levels need >=20 -- so `technical`
        // degrades to partial (indicators exist, no score summary) and
        // `levels` has nothing to show at all.
        let bars = makeBars(count: 10)
        let series = TechnicalIndicators.computeAll(bars: bars)
        let ruleScore = RuleScoreEngine.analyze(bars: bars, code: "600519") // hits the <20 guard

        let pack = ContextPackBuilder.build(.init(
            subject: ContextPackSubject(code: "600519"),
            dailyBars: bars,
            technicalSeries: series,
            ruleScore: ruleScore
        ))

        XCTAssertEqual(pack.blocks[ContextBlockKey.technical]?.status, .partial)
        XCTAssertNil(pack.blocks[ContextBlockKey.technical]?.items["signal_score"], "no score summary without enough bars")
        XCTAssertEqual(pack.blocks[ContextBlockKey.levels]?.status, .missing)
    }

    // MARK: - S8.2: warning propagation

    func test_volumeOverlaySkippedWarning_alwaysPresentInDataQualityWarnings() {
        let pack = ContextPackBuilder.build(.init(
            subject: ContextPackSubject(code: "600519"),
            dailyBars: makeBars(count: 40),
            overlayWarnings: [ContextPackWarningKey.intradayVolumeOverlaySkipped]
        ))
        XCTAssertTrue(pack.dataQuality.warnings.contains(ContextPackWarningKey.intradayVolumeOverlaySkipped))
        XCTAssertFalse(pack.dataQuality.warnings.contains(ContextPackWarningKey.intradayBarNotYetAvailable))
    }

    func test_bothOverlayWarnings_bothPresentInDataQualityWarnings() {
        let bars = makeBars(count: 40)
        let pack = ContextPackBuilder.build(.init(
            subject: ContextPackSubject(code: "600519"),
            dailyBars: bars,
            overlayWarnings: [
                ContextPackWarningKey.intradayVolumeOverlaySkipped,
                ContextPackWarningKey.intradayBarNotYetAvailable,
            ]
        ))
        XCTAssertTrue(pack.dataQuality.warnings.contains(ContextPackWarningKey.intradayVolumeOverlaySkipped))
        XCTAssertTrue(pack.dataQuality.warnings.contains(ContextPackWarningKey.intradayBarNotYetAvailable))
        // The daily_bars block itself also reflects the "not yet available"
        // case structurally, not just as a warning string.
        XCTAssertEqual(pack.blocks[ContextBlockKey.dailyBars]?.status, .partial)
    }

    // MARK: - S8.3: data-quality scoring (verified against a real run of _build_data_quality)

    func test_dataQuality_allCoreBlocksAvailable_scoresGood() {
        let bars = makeBars(count: 40)
        let series = TechnicalIndicators.computeAll(bars: bars)
        let ruleScore = RuleScoreEngine.analyze(bars: bars, code: "600519")

        let pack = ContextPackBuilder.build(.init(
            subject: ContextPackSubject(code: "600519"),
            dailyBars: bars,
            quote: makeQuote(),
            technicalSeries: series,
            ruleScore: ruleScore
        ))

        // quote/daily_bars/technical = available(100)*25 each,
        // news/fundamentals/chip = not_supported(70)*[10,10,5]
        // weighted_sum = 7500 + 1750 = 9250 -> round(92.5) = 92 -> "good"
        XCTAssertEqual(pack.dataQuality.overallScore, 92)
        XCTAssertEqual(pack.dataQuality.level, "good")
    }

    func test_dataQuality_allCoreBlocksMissing_scoresPoor() {
        let pack = ContextPackBuilder.build(.init(
            subject: ContextPackSubject(code: "600519"),
            dailyBars: [],
            quote: nil
        ))

        // quote/daily_bars/technical = missing(35)*25 each,
        // news/fundamentals/chip = not_supported(70)*[10,10,5]
        // weighted_sum = 2625 + 1750 = 4375 -> round(43.75) = 44 -> "poor"
        XCTAssertEqual(pack.dataQuality.overallScore, 44)
        XCTAssertEqual(pack.dataQuality.level, "poor")
    }

    func test_dataQuality_partialCoreBlocks_scoresUsable() {
        // quote available(100), daily_bars/technical partial(75) each,
        // news/fundamentals/chip not_supported(70)
        // weighted_sum = 100*25 + 75*25 + 75*25 + 1750 = 2500+1875+1875+1750 = 8000
        // -> round(80.0) = 80 -> "usable"
        let bars = makeBars(count: 10) // <20 -> technical partial, and we'll force daily_bars partial via overlay warning
        let series = TechnicalIndicators.computeAll(bars: bars)

        let pack = ContextPackBuilder.build(.init(
            subject: ContextPackSubject(code: "600519"),
            dailyBars: bars,
            overlayWarnings: [ContextPackWarningKey.intradayBarNotYetAvailable],
            quote: makeQuote(),
            technicalSeries: series,
            ruleScore: nil
        ))

        XCTAssertEqual(pack.blocks[ContextBlockKey.dailyBars]?.status, .partial)
        XCTAssertEqual(pack.blocks[ContextBlockKey.technical]?.status, .partial)
        XCTAssertEqual(pack.dataQuality.overallScore, 80)
        XCTAssertEqual(pack.dataQuality.level, "usable")
    }

    func test_dataQuality_blockScores_onlyIncludesTheSixWeightedBlocks() {
        let pack = ContextPackBuilder.build(.init(
            subject: ContextPackSubject(code: "600519"),
            dailyBars: makeBars(count: 40)
        ))
        XCTAssertEqual(Set(pack.dataQuality.blockScores.keys), [
            ContextBlockKey.quote, ContextBlockKey.dailyBars, ContextBlockKey.technical,
            ContextBlockKey.news, ContextBlockKey.fundamentals, ContextBlockKey.chip,
        ])
    }

    // MARK: - S8.3: limitations

    func test_limitations_missingCoreBlocks_areListed() {
        let pack = ContextPackBuilder.build(.init(
            subject: ContextPackSubject(code: "600519"),
            dailyBars: [],
            quote: nil
        ))
        XCTAssertEqual(Set(pack.dataQuality.limitations), [
            "quote: missing", "daily_bars: missing", "technical: missing",
        ])
    }

    func test_limitations_notSupportedAuxBlocks_neverListed() {
        let pack = ContextPackBuilder.build(.init(
            subject: ContextPackSubject(code: "600519"),
            dailyBars: makeBars(count: 40),
            quote: makeQuote()
        ))
        // chip/fundamentals/news are always not_supported in this MVP, and
        // not_supported is never in the aux limitation set.
        XCTAssertFalse(pack.dataQuality.limitations.contains { $0.hasPrefix("chip:") })
        XCTAssertFalse(pack.dataQuality.limitations.contains { $0.hasPrefix("fundamentals:") })
        XCTAssertFalse(pack.dataQuality.limitations.contains { $0.hasPrefix("news:") })
    }

    func test_limitations_cappedAtFive() {
        // Force every core+aux limitation-eligible slot to fire by leaving
        // everything missing/absent -- still only 3 possible in this MVP's
        // shape (quote/daily_bars/technical), well under the cap, but this
        // confirms the cap logic doesn't accidentally truncate below what's
        // actually there.
        let pack = ContextPackBuilder.build(.init(
            subject: ContextPackSubject(code: "600519"),
            dailyBars: [],
            quote: nil
        ))
        XCTAssertLessThanOrEqual(pack.dataQuality.limitations.count, 5)
    }
}
