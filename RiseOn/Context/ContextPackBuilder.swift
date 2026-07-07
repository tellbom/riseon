import Foundation

/// Swift port of `src/services/analysis_context_builder.py::AnalysisContextBuilder`
/// (task.md S8.2-S8.3, plan.md §7/§8).
///
/// Differences from the Python builder, all intentional (plan.md's MVP
/// scope, not omissions):
/// - `chip`/`fundamentals`/`news`/`capital_flow`/`events` are always
///   `not_supported` — there's no on-device source for any of them.
/// - `factors` is always `partial` at best: only the `technical` sub-slice
///   of `quant_factor_context` is computed on-device (window returns +
///   range position); `capital_flow`/`valuation`/`industry`/`fundamentals`/
///   `margin` sub-blocks never are.
/// - `levels` doesn't exist on the Python side at all — it's this app's
///   addition, carrying S7.3's `support_levels`/`resistance_levels` for the
///   LLM to reference when generating `sniper_points` (plan.md §0.5-1).
/// - `portfolio` isn't ported — that's a multi-stock Python concept;
///   `StockWorkspace` is single-stock by design (plan.md §5).
public enum ContextPackBuilder {

    // MARK: - Inputs

    /// Everything the builder needs, gathered from the earlier pipeline
    /// steps (S5's daily bars + overlay, S6's indicators, S7's rule score).
    /// The builder itself does no fetching — same "纪律" as
    /// `RealtimeOverlay`/`RuleScoreEngine`.
    public struct Inputs {
        public var subject: ContextPackSubject
        /// Post-`RealtimeOverlay` bars (already has today's overlay applied,
        /// if any) — ascending by date.
        public var dailyBars: [DailyBar]
        /// From `RealtimeOverlay.Result.warnings` (S5.2): always contains
        /// `intradayVolumeOverlaySkipped`, and conditionally
        /// `intradayBarNotYetAvailable`.
        public var overlayWarnings: [String]
        public var quote: Quote?
        /// Whether Step B (realtime quote) was attempted and failed —
        /// distinguishes "we tried and it broke" (`fetch_failed`, task.md
        /// S15.1) from "we never got that far" (`missing`). Only meaningful
        /// when `quote == nil`; ignored otherwise.
        public var quoteFetchFailed: Bool
        /// Whether Step A (fetch daily bars) was attempted and failed —
        /// same distinction as `quoteFetchFailed`, for `dailyBars`. This
        /// also cascades into `technical`/`factors`/`levels`: if there are
        /// no bars *because the fetch failed*, those derived blocks report
        /// `fetch_failed` too rather than a generic `missing`, so the
        /// person/LLM can tell "network broke" from "not enough history
        /// yet" apart (task.md S15.1's "如实声明缺失").
        public var dailyBarsFetchFailed: Bool
        public var technicalSeries: TechnicalIndicators.Series?
        public var latestSignals: TechnicalIndicators.LatestSignals?
        public var ruleScore: RuleScore?
        /// `FactorWindows.windowReturns(bars:)` output (S6.3).
        public var windowReturns: [Int: Double]
        /// `FactorWindows.rangePosition(bars:)` output, window=20 (S6.3).
        public var rangePosition20d: Double?

        public init(
            subject: ContextPackSubject,
            dailyBars: [DailyBar] = [],
            overlayWarnings: [String] = [],
            quote: Quote? = nil,
            quoteFetchFailed: Bool = false,
            dailyBarsFetchFailed: Bool = false,
            technicalSeries: TechnicalIndicators.Series? = nil,
            latestSignals: TechnicalIndicators.LatestSignals? = nil,
            ruleScore: RuleScore? = nil,
            windowReturns: [Int: Double] = [:],
            rangePosition20d: Double? = nil
        ) {
            self.subject = subject
            self.dailyBars = dailyBars
            self.overlayWarnings = overlayWarnings
            self.quote = quote
            self.quoteFetchFailed = quoteFetchFailed
            self.dailyBarsFetchFailed = dailyBarsFetchFailed
            self.technicalSeries = technicalSeries
            self.latestSignals = latestSignals
            self.ruleScore = ruleScore
            self.windowReturns = windowReturns
            self.rangePosition20d = rangePosition20d
        }
    }

    // MARK: - Build (S8.2)

    public static func build(_ inputs: Inputs) -> ContextPack {
        var blocks: [String: ContextBlock] = [:]

        blocks[ContextBlockKey.quote] = buildQuoteBlock(quote: inputs.quote, fetchFailed: inputs.quoteFetchFailed)
        blocks[ContextBlockKey.dailyBars] = buildDailyBarsBlock(
            bars: inputs.dailyBars,
            overlayWarnings: inputs.overlayWarnings,
            fetchFailed: inputs.dailyBarsFetchFailed
        )
        blocks[ContextBlockKey.technical] = buildTechnicalBlock(
            bars: inputs.dailyBars,
            series: inputs.technicalSeries,
            signals: inputs.latestSignals,
            ruleScore: inputs.ruleScore,
            dailyBarsFetchFailed: inputs.dailyBarsFetchFailed
        )
        blocks[ContextBlockKey.factors] = buildFactorsBlock(
            bars: inputs.dailyBars,
            windowReturns: inputs.windowReturns,
            rangePosition20d: inputs.rangePosition20d,
            dailyBarsFetchFailed: inputs.dailyBarsFetchFailed
        )
        blocks[ContextBlockKey.levels] = buildLevelsBlock(
            bars: inputs.dailyBars,
            ruleScore: inputs.ruleScore,
            dailyBarsFetchFailed: inputs.dailyBarsFetchFailed
        )
        blocks[ContextBlockKey.chip] = notSupportedBlock(reason: "端上无法直连筹码分布数据源")
        blocks[ContextBlockKey.fundamentals] = notSupportedBlock(reason: "端上无法直连基本面数据源")
        blocks[ContextBlockKey.news] = notSupportedBlock(reason: "端上不支持新闻/情报联网检索")
        blocks[ContextBlockKey.capitalFlow] = notSupportedBlock(reason: "端上无法直连资金流数据源")
        blocks[ContextBlockKey.events] = notSupportedBlock(reason: "端上不支持事件日历")

        // Overlay warnings (volume-skip, maybe bar-not-yet-available) land
        // in `dataQuality.warnings`, mirroring how the Python builder
        // threads block-building warnings into `_build_data_quality`'s
        // `warnings` parameter rather than duplicating them per-block.
        let dataQuality = buildDataQuality(blocks: blocks, warnings: inputs.overlayWarnings)

        return ContextPack(subject: inputs.subject, blocks: blocks, dataQuality: dataQuality)
    }

    // MARK: - Block builders

    private static func buildQuoteBlock(quote: Quote?, fetchFailed: Bool) -> ContextBlock {
        guard let quote else {
            let status: ContextFieldStatus = fetchFailed ? .fetchFailed : .missing
            let reason = fetchFailed ? "拉取实时行情失败" : "未获取到实时行情"
            return ContextBlock(status: status, items: ["quote": ContextItem(status: status, missingReason: reason)])
        }
        let items: [String: ContextItem] = [
            "price": ContextItem(status: .available, value: .double(quote.price)),
            "previous_close": ContextItem(status: .available, value: .double(quote.previousClose)),
            "open": ContextItem(status: .available, value: .double(quote.open)),
            "high": ContextItem(status: .available, value: .double(quote.high)),
            "low": ContextItem(status: .available, value: .double(quote.low)),
            "change_amount": ContextItem(status: .available, value: .double(quote.changeAmount)),
            "change_percent": ContextItem(status: .available, value: .double(quote.changePercent)),
        ]
        return ContextBlock(status: .available, items: items, source: "tencent_realtime")
    }

    private static func buildDailyBarsBlock(bars: [DailyBar], overlayWarnings: [String], fetchFailed: Bool) -> ContextBlock {
        guard let last = bars.last else {
            let status: ContextFieldStatus = fetchFailed ? .fetchFailed : .missing
            let reason = fetchFailed ? "拉取日线失败" : "未获取到日线数据"
            return ContextBlock(status: status, items: ["daily_bars": ContextItem(status: status, missingReason: reason)])
        }
        // Historically-complete but today's bar hasn't been published yet
        // (plan.md §0.5-7) -> partial, not a clean available; the daily
        // endpoint just hasn't caught up to "now" yet.
        let status: ContextFieldStatus = overlayWarnings.contains(ContextPackWarningKey.intradayBarNotYetAvailable) ? .partial : .available
        let items: [String: ContextItem] = [
            "count": ContextItem(status: .available, value: .int(bars.count)),
            "latest_date": ContextItem(status: .available, value: .string(last.date)),
            "latest_close": ContextItem(status: .available, value: .double(last.close)),
        ]
        return ContextBlock(status: status, items: items, source: "tencent_daily")
    }

    private static func buildTechnicalBlock(
        bars: [DailyBar],
        series: TechnicalIndicators.Series?,
        signals: TechnicalIndicators.LatestSignals?,
        ruleScore: RuleScore?,
        dailyBarsFetchFailed: Bool
    ) -> ContextBlock {
        guard !bars.isEmpty, let series, let last = series.ma5.indices.last else {
            let status: ContextFieldStatus = dailyBarsFetchFailed ? .fetchFailed : .missing
            let reason = dailyBarsFetchFailed ? "日线拉取失败，无法计算技术指标" : "无日线数据，无法计算技术指标"
            return ContextBlock(status: status, items: ["technical": ContextItem(status: status, missingReason: reason)])
        }

        var items: [String: ContextItem] = [
            "ma5": ContextItem(status: .available, value: .double(series.ma5[last])),
            "ma10": ContextItem(status: .available, value: .double(series.ma10[last])),
            "ma20": ContextItem(status: .available, value: .double(series.ma20[last])),
            "ma60": ContextItem(status: .available, value: .double(series.ma60[last])),
            "rsi6": ContextItem(status: .available, value: .double(series.rsi6[last])),
            "rsi12": ContextItem(status: .available, value: .double(series.rsi12[last])),
            "rsi24": ContextItem(status: .available, value: .double(series.rsi24[last])),
            "macd_dif": ContextItem(status: .available, value: .double(series.dif[last])),
            "macd_dea": ContextItem(status: .available, value: .double(series.dea[last])),
            "macd_bar": ContextItem(status: .available, value: .double(series.macd[last])),
        ]

        if let signals {
            items["macd_golden_cross"] = ContextItem(status: .available, value: .bool(signals.macdGoldenCross))
            items["macd_dead_cross"] = ContextItem(status: .available, value: .bool(signals.macdDeadCross))
            items["kdj_overbought"] = ContextItem(status: .available, value: .bool(signals.kdjOverbought))
            items["kdj_oversold"] = ContextItem(status: .available, value: .bool(signals.kdjOversold))
        }

        // The "评分摘要" (score summary) task.md S8.2 asks for — only
        // meaningful once RuleScoreEngine has enough bars to score at all
        // (S7's own 20-bar minimum), not just enough for min_periods=1 MAs.
        let hasEnoughForScoring = bars.count >= RuleScoreEngine.minimumBarsRequired
        if hasEnoughForScoring, let ruleScore {
            items["trend_status"] = ContextItem(status: .available, value: .string(ruleScore.trendStatus.rawValue))
            items["signal_score"] = ContextItem(status: .available, value: .int(ruleScore.signalScore))
            items["buy_signal"] = ContextItem(status: .available, value: .string(ruleScore.buySignal.rawValue))
            items["macd_status"] = ContextItem(status: .available, value: .string(ruleScore.macdStatus.rawValue))
            items["rsi_status"] = ContextItem(status: .available, value: .string(ruleScore.rsiStatus.rawValue))
        }

        return ContextBlock(status: hasEnoughForScoring ? .available : .partial, items: items, source: "on_device_technical_indicators")
    }

    private static func buildFactorsBlock(
        bars: [DailyBar],
        windowReturns: [Int: Double],
        rangePosition20d: Double?,
        dailyBarsFetchFailed: Bool
    ) -> ContextBlock {
        guard !bars.isEmpty else {
            let status: ContextFieldStatus = dailyBarsFetchFailed ? .fetchFailed : .missing
            let reason = dailyBarsFetchFailed ? "日线拉取失败，无法计算因子窗口" : "无日线数据"
            return ContextBlock(status: status, items: ["factors": ContextItem(status: status, missingReason: reason)])
        }

        var items: [String: ContextItem] = [:]
        for window in windowReturns.keys.sorted() {
            items["return_\(window)d_pct"] = ContextItem(status: .available, value: .double(windowReturns[window]!))
        }
        if let rangePosition20d {
            items["range_position_20d"] = ContextItem(status: .available, value: .double(rangePosition20d))
        }

        // Always partial, even when every window return we DO compute
        // succeeded: only the `technical` sub-slice of
        // `quant_factor_context` exists on-device (plan.md §2.2/§7).
        return ContextBlock(
            status: .partial,
            items: items,
            metadata: [
                "missing_subblocks": .array(
                    ["capital_flow", "valuation", "industry", "fundamentals", "margin"].map { .string($0) }
                ),
            ]
        )
    }

    private static func buildLevelsBlock(bars: [DailyBar], ruleScore: RuleScore?, dailyBarsFetchFailed: Bool) -> ContextBlock {
        guard let ruleScore, bars.count >= RuleScoreEngine.minimumBarsRequired else {
            // Only actually a *fetch* failure if there's no daily-bar data
            // at all because of it; bars merely being too few (but present)
            // to reach the 20-bar minimum is still `missing`, not `fetch_failed`.
            let status: ContextFieldStatus = (bars.isEmpty && dailyBarsFetchFailed) ? .fetchFailed : .missing
            let reason = status == .fetchFailed ? "日线拉取失败，无法计算支撑/阻力位" : "数据不足，无法计算支撑/阻力位"
            return ContextBlock(status: status, items: ["levels": ContextItem(status: status, missingReason: reason)])
        }

        var items: [String: ContextItem] = [
            "support_levels": ContextItem(status: .available, value: .doubleArray(ruleScore.supportLevels)),
            "resistance_levels": ContextItem(status: .available, value: .doubleArray(ruleScore.resistanceLevels)),
        ]
        if let stopLoss = RuleScoreEngine.stopLossFallback(for: ruleScore) {
            items["stop_loss_fallback"] = ContextItem(status: .available, value: .double(stopLoss))
        }
        return ContextBlock(status: .available, items: items)
    }

    private static func notSupportedBlock(reason: String) -> ContextBlock {
        ContextBlock(
            status: .notSupported,
            items: ["value": ContextItem(status: .notSupported, missingReason: reason)]
        )
    }

    // MARK: - Data quality (S8.3, analysis_context_builder.py::_build_data_quality)

    /// `_QUALITY_BLOCK_WEIGHTS` — only these six blocks count toward
    /// `overall_score`; `factors`/`levels`/`capital_flow`/`events` never do,
    /// matching the Python source exactly (it has no `levels` block at all,
    /// and doesn't weight its own `factors`/`events` either).
    public static let qualityBlockWeights: [String: Int] = [
        ContextBlockKey.quote: 25,
        ContextBlockKey.dailyBars: 25,
        ContextBlockKey.technical: 25,
        ContextBlockKey.news: 10,
        ContextBlockKey.fundamentals: 10,
        ContextBlockKey.chip: 5,
    ]

    /// `_STATUS_SCORES`.
    public static let statusScores: [ContextFieldStatus: Int] = [
        .available: 100,
        .partial: 75,
        .estimated: 75,
        .notSupported: 70,
        .fallback: 65,
        .stale: 50,
        .missing: 35,
        .fetchFailed: 25,
    ]

    /// `_CORE_LIMITATION_STATUSES`.
    private static let coreLimitationStatuses: Set<ContextFieldStatus> = [.stale, .fallback, .missing, .fetchFailed, .partial, .estimated]
    /// `_AUX_LIMITATION_STATUSES`.
    private static let auxLimitationStatuses: Set<ContextFieldStatus> = [.fetchFailed, .fallback, .stale]

    private static func buildDataQuality(blocks: [String: ContextBlock], warnings: [String]) -> DataQuality {
        var blockScores: [String: Int] = [:]
        var weightedSum = 0
        for (key, weight) in qualityBlockWeights {
            let status = blocks[key]?.status ?? .missing
            let score = statusScores[status] ?? statusScores[.missing]!
            blockScores[key] = score
            weightedSum += score * weight
        }

        // Weights sum to exactly 100, so this is the weighted average
        // directly. `.toNearestOrEven` matches Python 3's `round()`
        // (banker's rounding) for the occasional exact `.5` case.
        let overallScore = Int((Double(weightedSum) / 100).rounded(.toNearestOrEven))

        return DataQuality(
            overallScore: overallScore,
            level: qualityLevel(overallScore),
            blockScores: blockScores,
            limitations: qualityLimitations(blocks: blocks),
            warnings: warnings
        )
    }

    /// `_quality_level`.
    private static func qualityLevel(_ score: Int) -> String {
        if score >= 85 { return "good" }
        if score >= 70 { return "usable" }
        if score >= 55 { return "limited" }
        return "poor"
    }

    /// `_quality_limitations` — note `not_supported` never counts as a
    /// "limitation" in either list (it's an expected, permanent MVP
    /// condition, not a degraded fetch), so `chip`/`fundamentals`/`news`
    /// being permanently `not_supported` never shows up here.
    private static func qualityLimitations(blocks: [String: ContextBlock]) -> [String] {
        var limitations: [String] = []

        for key in [ContextBlockKey.quote, ContextBlockKey.dailyBars, ContextBlockKey.technical] {
            let status = blocks[key]?.status ?? .missing
            if coreLimitationStatuses.contains(status) {
                limitations.append("\(key): \(status.rawValue)")
            }
        }
        for key in [ContextBlockKey.news, ContextBlockKey.fundamentals, ContextBlockKey.chip] {
            let status = blocks[key]?.status ?? .missing
            if auxLimitationStatuses.contains(status) {
                limitations.append("\(key): \(status.rawValue)")
            }
        }

        return Array(limitations.prefix(5))
    }
}
