import Foundation

/// Swift port of `src/stock_analyzer.py::StockTrendAnalyzer` (task.md
/// S7.1-S7.4, plan.md §0.5-1/§0.5-5/§0.5-6/§8). Pure function, no I/O.
///
/// **What this does NOT do** (plan.md §0.5-1, task.md S7.4): produce
/// `ideal_buy`/`secondary_buy`/`take_profit`. Those are LLM-generated
/// (`dashboard.battle_plan.sniper_points`, see S9/S10). This engine only
/// produces `supportLevels`/`resistanceLevels` (S7.3) for the LLM to use as
/// input, plus a deterministic `stopLossFallback(for:)` for when the LLM
/// omits `stop_loss` (S7.4).
///
/// **MA independence** (§0.5-6): the moving averages here use the
/// *full-window* semantics of `stock_analyzer.py::_calculate_mas`
/// (`rolling(window:).mean()`, NaN until the window fills; `MA60` is the
/// **entire MA20 column** when there are under 60 bars total, not a
/// per-row fallback) — this is intentionally a separate implementation from
/// `TechnicalIndicators`'s `min_periods=1` MA, and the two must stay
/// separate. MACD and RSI, by contrast, use the *exact same* formulas in
/// both Python sources, so this engine reuses
/// `TechnicalIndicators.macd`/`TechnicalIndicators.rsiWilder` directly
/// rather than reimplementing them a second time.
public enum RuleScoreEngine {

    // MARK: - Parameters (stock_analyzer.py::StockTrendAnalyzer class constants)

    public static let volumeShrinkRatio = 0.7     // VOLUME_SHRINK_RATIO
    public static let volumeHeavyRatio = 1.5      // VOLUME_HEAVY_RATIO
    public static let maSupportTolerance = 0.02   // MA_SUPPORT_TOLERANCE
    public static let macdSlowPeriod = 26         // MACD_SLOW — MACD needs this many bars
    public static let rsiLongPeriod = 24          // RSI_LONG — RSI needs this many bars
    public static let rsiOverboughtThreshold = 70.0
    public static let rsiOversoldThreshold = 30.0
    /// `src/config.py`'s `bias_threshold` default (env-overridable there;
    /// exposed here as a plain parameter since this app has no equivalent
    /// server-side config system).
    public static let defaultBiasThreshold = 5.0
    /// `analyze()`'s own minimum — below this, Python returns a
    /// near-default result with only `risk_factors` populated.
    public static let minimumBarsRequired = 20

    // MARK: - Entry point (stock_analyzer.py::StockTrendAnalyzer.analyze)

    /// `bars` must be ascending by date (same convention as
    /// `TencentDailyProvider`'s output). Mirrors `analyze()`'s guard: fewer
    /// than `minimumBarsRequired` (20) bars returns a mostly-default
    /// `RuleScore` with only `riskFactors` populated, same as Python leaving
    /// `TrendAnalysisResult`'s dataclass defaults untouched.
    public static func analyze(bars: [DailyBar], code: String, biasThreshold: Double = defaultBiasThreshold) -> RuleScore {
        guard bars.count >= minimumBarsRequired else {
            var result = RuleScore(code: code)
            result.riskFactors = ["数据不足，无法完成分析"]
            return result
        }

        let closes = bars.map(\.close)

        let ma5Series = fullWindowMovingAverage(closes, period: 5)
        let ma10Series = fullWindowMovingAverage(closes, period: 10)
        let ma20Series = fullWindowMovingAverage(closes, period: 20)
        // MA60: the *entire column* is MA20 when there are under 60 bars —
        // not a per-row fallback (stock_analyzer.py::_calculate_mas).
        let ma60Series = bars.count >= 60 ? fullWindowMovingAverage(closes, period: 60) : ma20Series

        var result = RuleScore(code: code)
        let last = bars.count - 1
        result.currentPrice = closes[last]
        result.ma5 = ma5Series[last]
        result.ma10 = ma10Series[last]
        result.ma20 = ma20Series[last]
        result.ma60 = ma60Series[last]

        analyzeTrend(bars: bars, ma5: ma5Series, ma20: ma20Series, result: &result)
        calculateBias(result: &result)
        analyzeVolume(bars: bars, result: &result)
        analyzeSupportResistance(bars: bars, result: &result)

        if bars.count >= macdSlowPeriod {
            let (dif, dea, macdHist) = TechnicalIndicators.macd(closes: closes)
            analyzeMACD(dif: dif, dea: dea, macdHist: macdHist, bars: bars, result: &result)
        } else {
            result.macdSignal = "数据不足"
        }

        if bars.count >= rsiLongPeriod {
            let rsi6 = TechnicalIndicators.rsiWilder(closes: closes, period: 6)
            let rsi12 = TechnicalIndicators.rsiWilder(closes: closes, period: 12)
            let rsi24 = TechnicalIndicators.rsiWilder(closes: closes, period: 24)
            analyzeRSI(rsi6: rsi6, rsi12: rsi12, rsi24: rsi24, bars: bars, result: &result)
        } else {
            result.rsiSignal = "数据不足"
        }

        generateSignal(result: &result, biasThreshold: biasThreshold)
        return result
    }

    /// `stop_loss ← support_levels[0]` deterministic fallback (task.md S7.4,
    /// plan.md §0.5-1) — used only when the LLM-generated `sniper_points`
    /// omits `stop_loss`. `nil` if there are no support levels at all.
    public static func stopLossFallback(for result: RuleScore) -> Double? {
        result.supportLevels.first
    }

    // MARK: - Trend (stock_analyzer.py::_analyze_trend)

    private static func analyzeTrend(bars: [DailyBar], ma5: [Double], ma20: [Double], result: inout RuleScore) {
        let count = bars.count
        let last = count - 1
        // `len(df) >= 5` is always true here (analyze() already requires
        // >= 20 bars) — kept as a literal port of the Python guard anyway.
        let prevIndex = count >= 5 ? count - 5 : last

        let currentMA5 = result.ma5
        let currentMA10 = result.ma10
        let currentMA20 = result.ma20

        if currentMA5 > currentMA10 && currentMA10 > currentMA20 {
            let prevMA5 = ma5[prevIndex]
            let prevMA20 = ma20[prevIndex]
            // NaN-safe by construction: `prevMA20 > 0` is `false` when
            // `prevMA20` is NaN (an early, not-yet-full window), matching
            // pandas' `if prev['MA20'] > 0 else 0` exactly.
            let prevSpread = prevMA20 > 0 ? (prevMA5 - prevMA20) / prevMA20 * 100 : 0
            let currSpread = currentMA20 > 0 ? (currentMA5 - currentMA20) / currentMA20 * 100 : 0

            if currSpread > prevSpread && currSpread > 5 {
                result.trendStatus = .strongBull
                result.maAlignment = "强势多头排列，均线发散上行"
                result.trendStrength = 90
            } else {
                result.trendStatus = .bull
                result.maAlignment = "多头排列 MA5>MA10>MA20"
                result.trendStrength = 75
            }
        } else if currentMA5 > currentMA10 && currentMA10 <= currentMA20 {
            result.trendStatus = .weakBull
            result.maAlignment = "弱势多头，MA5>MA10 但 MA10≤MA20"
            result.trendStrength = 55
        } else if currentMA5 < currentMA10 && currentMA10 < currentMA20 {
            let prevMA5 = ma5[prevIndex]
            let prevMA20 = ma20[prevIndex]
            let prevSpread = prevMA5 > 0 ? (prevMA20 - prevMA5) / prevMA5 * 100 : 0
            let currSpread = currentMA5 > 0 ? (currentMA20 - currentMA5) / currentMA5 * 100 : 0

            if currSpread > prevSpread && currSpread > 5 {
                result.trendStatus = .strongBear
                result.maAlignment = "强势空头排列，均线发散下行"
                result.trendStrength = 10
            } else {
                result.trendStatus = .bear
                result.maAlignment = "空头排列 MA5<MA10<MA20"
                result.trendStrength = 25
            }
        } else if currentMA5 < currentMA10 && currentMA10 >= currentMA20 {
            result.trendStatus = .weakBear
            result.maAlignment = "弱势空头，MA5<MA10 但 MA10≥MA20"
            result.trendStrength = 40
        } else {
            result.trendStatus = .consolidation
            result.maAlignment = "均线缠绕，趋势不明"
            result.trendStrength = 50
        }
    }

    // MARK: - Bias (stock_analyzer.py::_calculate_bias)

    private static func calculateBias(result: inout RuleScore) {
        let price = result.currentPrice
        if result.ma5 > 0 {
            result.biasMA5 = (price - result.ma5) / result.ma5 * 100
        }
        if result.ma10 > 0 {
            result.biasMA10 = (price - result.ma10) / result.ma10 * 100
        }
        if result.ma20 > 0 {
            result.biasMA20 = (price - result.ma20) / result.ma20 * 100
        }
    }

    // MARK: - Volume (stock_analyzer.py::_analyze_volume)

    private static func analyzeVolume(bars: [DailyBar], result: inout RuleScore) {
        let count = bars.count
        guard count >= 5 else { return } // dead in practice (analyze() requires >=20); kept for fidelity

        let last = count - 1
        // `df['volume'].iloc[-6:-1]`: 5 bars before the latest one. Clamped
        // to `max(0, count-6)` so this degrades gracefully (fewer than 5
        // values averaged) instead of crashing if ever called with <6 bars
        // directly, matching pandas' own out-of-range slice clamping.
        let start = max(0, count - 6)
        let volumeWindow = bars[start..<last].map(\.volume)
        guard !volumeWindow.isEmpty else { return }
        let vol5dAvg = volumeWindow.reduce(0, +) / Double(volumeWindow.count)

        if vol5dAvg > 0 {
            result.volumeRatio5d = bars[last].volume / vol5dAvg
        }

        let prevClose = bars[last - 1].close
        let priceChange = prevClose != 0 ? (bars[last].close - prevClose) / prevClose * 100 : 0

        if result.volumeRatio5d >= volumeHeavyRatio {
            if priceChange > 0 {
                result.volumeStatus = .heavyVolumeUp
                result.volumeTrend = "放量上涨，多头力量强劲"
            } else {
                result.volumeStatus = .heavyVolumeDown
                result.volumeTrend = "放量下跌，注意风险"
            }
        } else if result.volumeRatio5d <= volumeShrinkRatio {
            if priceChange > 0 {
                result.volumeStatus = .shrinkVolumeUp
                result.volumeTrend = "缩量上涨，上攻动能不足"
            } else {
                result.volumeStatus = .shrinkVolumeDown
                result.volumeTrend = "缩量回调，洗盘特征明显（好）"
            }
        } else {
            result.volumeStatus = .normal
            result.volumeTrend = "量能正常"
        }
    }

    // MARK: - Support / resistance (S7.3, stock_analyzer.py::_analyze_support_resistance:448-479)

    private static func analyzeSupportResistance(bars: [DailyBar], result: inout RuleScore) {
        let price = result.currentPrice

        // MA5 support (line 459-461): 2% tolerance AND price >= MA5.
        if result.ma5 > 0 {
            let distance = abs(price - result.ma5) / result.ma5
            if distance <= maSupportTolerance && price >= result.ma5 {
                result.supportMA5 = true
                result.supportLevels.append(result.ma5)
            }
        }

        // MA10 support (line 464-469): same tolerance, deduped against
        // what's already in `supportLevels`.
        if result.ma10 > 0 {
            let distance = abs(price - result.ma10) / result.ma10
            if distance <= maSupportTolerance && price >= result.ma10 {
                result.supportMA10 = true
                if !result.supportLevels.contains(result.ma10) {
                    result.supportLevels.append(result.ma10)
                }
            }
        }

        // MA20 support (line 472-473, plan.md §0.5-5): **no tolerance at
        // all**, just `price >= MA20` — and, matching the Python source
        // exactly, **no dedup check** here either (unlike MA10's). If MA20
        // happens to equal an already-appended MA5/MA10 value, Python would
        // append a literal duplicate, and so do we — faithful port, not a
        // bug we're "fixing".
        if result.ma20 > 0 && price >= result.ma20 {
            result.supportLevels.append(result.ma20)
        }

        // Resistance (line 476-479): 20-day high, if it's still above price.
        if bars.count >= 20 {
            if let recentHigh = bars.suffix(20).map(\.high).max(), recentHigh > price {
                result.resistanceLevels.append(recentHigh)
            }
        }
    }

    // MARK: - MACD (stock_analyzer.py::_analyze_macd)

    private static func analyzeMACD(dif: [Double], dea: [Double], macdHist: [Double], bars: [DailyBar], result: inout RuleScore) {
        let count = bars.count
        guard count >= macdSlowPeriod else {
            result.macdSignal = "数据不足"
            return
        }
        let last = count - 1
        let prev = count - 2

        result.macdDIF = dif[last]
        result.macdDEA = dea[last]
        result.macdBar = macdHist[last]

        let prevDifDea = dif[prev] - dea[prev]
        let currDifDea = result.macdDIF - result.macdDEA
        let isGoldenCross = prevDifDea <= 0 && currDifDea > 0
        let isDeathCross = prevDifDea >= 0 && currDifDea < 0

        let prevZero = dif[prev]
        let currZero = result.macdDIF
        let isCrossingUp = prevZero <= 0 && currZero > 0
        let isCrossingDown = prevZero >= 0 && currZero < 0

        if isGoldenCross && currZero > 0 {
            result.macdStatus = .goldenCrossZero
            result.macdSignal = "⭐ 零轴上金叉，强烈买入信号！"
        } else if isCrossingUp {
            result.macdStatus = .crossingUp
            result.macdSignal = "⚡ DIF上穿零轴，趋势转强"
        } else if isGoldenCross {
            result.macdStatus = .goldenCross
            result.macdSignal = "✅ 金叉，趋势向上"
        } else if isDeathCross {
            result.macdStatus = .deathCross
            result.macdSignal = "❌ 死叉，趋势向下"
        } else if isCrossingDown {
            result.macdStatus = .crossingDown
            result.macdSignal = "⚠️ DIF下穿零轴，趋势转弱"
        } else if result.macdDIF > 0 && result.macdDEA > 0 {
            result.macdStatus = .bullish
            result.macdSignal = "✓ 多头排列，持续上涨"
        } else if result.macdDIF < 0 && result.macdDEA < 0 {
            result.macdStatus = .bearish
            result.macdSignal = "⚠ 空头排列，持续下跌"
        } else {
            result.macdStatus = .bullish
            result.macdSignal = " MACD 中性区域"
        }
    }

    // MARK: - RSI (stock_analyzer.py::_analyze_rsi)

    private static func analyzeRSI(rsi6: [Double], rsi12: [Double], rsi24: [Double], bars: [DailyBar], result: inout RuleScore) {
        let count = bars.count
        guard count >= rsiLongPeriod else {
            result.rsiSignal = "数据不足"
            return
        }
        let last = count - 1
        result.rsi6 = rsi6[last]
        result.rsi12 = rsi12[last]
        result.rsi24 = rsi24[last]

        let rsiMid = result.rsi12
        if rsiMid > rsiOverboughtThreshold {
            result.rsiStatus = .overbought
            result.rsiSignal = "⚠️ RSI超买(\(oneDecimal(rsiMid))>70)，短期回调风险高"
        } else if rsiMid > 60 {
            result.rsiStatus = .strongBuy
            result.rsiSignal = "✅ RSI强势(\(oneDecimal(rsiMid)))，多头力量充足"
        } else if rsiMid >= 40 {
            result.rsiStatus = .neutral
            result.rsiSignal = " RSI中性(\(oneDecimal(rsiMid)))，震荡整理中"
        } else if rsiMid >= rsiOversoldThreshold {
            result.rsiStatus = .weak
            result.rsiSignal = "⚡ RSI弱势(\(oneDecimal(rsiMid)))，关注反弹"
        } else {
            result.rsiStatus = .oversold
            result.rsiSignal = "⭐ RSI超卖(\(oneDecimal(rsiMid))<30)，反弹机会大"
        }
    }

    // MARK: - Signal (stock_analyzer.py::_generate_signal — the weighted scoring)

    private static func generateSignal(result: inout RuleScore, biasThreshold: Double) {
        var score = 0
        var reasons: [String] = []
        var risks: [String] = []

        // === 趋势（30分）===
        let trendScore: Int
        switch result.trendStatus {
        case .strongBull: trendScore = 30
        case .bull: trendScore = 26
        case .weakBull: trendScore = 18
        case .consolidation: trendScore = 12
        case .weakBear: trendScore = 8
        case .bear: trendScore = 4
        case .strongBear: trendScore = 0
        }
        score += trendScore
        if result.trendStatus == .strongBull || result.trendStatus == .bull {
            reasons.append("✅ \(result.trendStatus.rawValue)，顺势做多")
        } else if result.trendStatus == .bear || result.trendStatus == .strongBear {
            risks.append("⚠️ \(result.trendStatus.rawValue)，不宜做多")
        }

        // === 乖离率（20分，强势趋势补偿）===
        let bias = result.biasMA5
        let isStrongTrend = result.trendStatus == .strongBull && result.trendStrength >= 70
        let effectiveThreshold = isStrongTrend ? biasThreshold * 1.5 : biasThreshold

        // Literal if/elif-chain port — branch *order* matters (later
        // conditions assume earlier ones already failed), so this is
        // deliberately not reorganized into a "cleaner" form.
        if bias < 0 {
            if bias > -3 {
                score += 20
                reasons.append("✅ 价格略低于MA5(\(oneDecimal(bias))%)，回踩买点")
            } else if bias > -5 {
                score += 16
                reasons.append("✅ 价格回踩MA5(\(oneDecimal(bias))%)，观察支撑")
            } else {
                score += 8
                risks.append("⚠️ 乖离率过大(\(oneDecimal(bias))%)，可能破位")
            }
        } else if bias < 2 {
            score += 18
            reasons.append("✅ 价格贴近MA5(\(oneDecimal(bias))%)，介入好时机")
        } else if bias < biasThreshold {
            score += 14
            reasons.append("⚡ 价格略高于MA5(\(oneDecimal(bias))%)，可小仓介入")
        } else if bias > effectiveThreshold {
            score += 4
            risks.append("❌ 乖离率过高(\(oneDecimal(bias))%>\(oneDecimal(effectiveThreshold))%)，严禁追高！")
        } else if bias > biasThreshold && isStrongTrend {
            score += 10
            reasons.append("⚡ 强势趋势中乖离率偏高(\(oneDecimal(bias))%)，可轻仓追踪")
        } else {
            score += 4
            risks.append("❌ 乖离率过高(\(oneDecimal(bias))%>\(oneDecimal(biasThreshold))%)，严禁追高！")
        }

        // === 量能（15分）===
        let volumeScore: Int
        switch result.volumeStatus {
        case .shrinkVolumeDown: volumeScore = 15
        case .heavyVolumeUp: volumeScore = 12
        case .normal: volumeScore = 10
        case .shrinkVolumeUp: volumeScore = 6
        case .heavyVolumeDown: volumeScore = 0
        }
        score += volumeScore
        if result.volumeStatus == .shrinkVolumeDown {
            reasons.append("✅ 缩量回调，主力洗盘")
        } else if result.volumeStatus == .heavyVolumeDown {
            risks.append("⚠️ 放量下跌，注意风险")
        }

        // === 支撑（10分）===
        if result.supportMA5 {
            score += 5
            reasons.append("✅ MA5支撑有效")
        }
        if result.supportMA10 {
            score += 5
            reasons.append("✅ MA10支撑有效")
        }

        // === MACD（15分）===
        let macdScore: Int
        switch result.macdStatus {
        case .goldenCrossZero: macdScore = 15
        case .goldenCross: macdScore = 12
        case .crossingUp: macdScore = 10
        case .bullish: macdScore = 8
        case .bearish: macdScore = 2
        case .crossingDown: macdScore = 0
        case .deathCross: macdScore = 0
        }
        score += macdScore
        if result.macdStatus == .goldenCrossZero || result.macdStatus == .goldenCross {
            reasons.append("✅ \(result.macdSignal)")
        } else if result.macdStatus == .deathCross || result.macdStatus == .crossingDown {
            risks.append("⚠️ \(result.macdSignal)")
        } else {
            reasons.append(result.macdSignal)
        }

        // === RSI（10分）===
        let rsiScore: Int
        switch result.rsiStatus {
        case .oversold: rsiScore = 10
        case .strongBuy: rsiScore = 8
        case .neutral: rsiScore = 5
        case .weak: rsiScore = 3
        case .overbought: rsiScore = 0
        }
        score += rsiScore
        if result.rsiStatus == .oversold || result.rsiStatus == .strongBuy {
            reasons.append("✅ \(result.rsiSignal)")
        } else if result.rsiStatus == .overbought {
            risks.append("⚠️ \(result.rsiSignal)")
        } else {
            reasons.append(result.rsiSignal)
        }

        result.signalScore = score
        result.signalReasons = reasons
        result.riskFactors = risks

        // === 综合判断（买入信号）===
        if score >= 75 && (result.trendStatus == .strongBull || result.trendStatus == .bull) {
            result.buySignal = .strongBuy
        } else if score >= 60 && (result.trendStatus == .strongBull || result.trendStatus == .bull || result.trendStatus == .weakBull) {
            result.buySignal = .buy
        } else if score >= 45 {
            result.buySignal = .hold
        } else if score >= 30 {
            result.buySignal = .wait
        } else if result.trendStatus == .bear || result.trendStatus == .strongBear {
            result.buySignal = .strongSell
        } else {
            result.buySignal = .sell
        }
    }

    // MARK: - Helpers

    /// `rolling(window: period).mean()` — pandas' **default** `min_periods`
    /// (equal to `period`): `NaN` until the window is fully populated. This
    /// is deliberately a separate implementation from
    /// `TechnicalIndicators`'s `min_periods=1` MA (§0.5-6) — do not merge them.
    private static func fullWindowMovingAverage(_ values: [Double], period: Int) -> [Double] {
        guard !values.isEmpty else { return [] }
        return values.indices.map { i -> Double in
            guard i >= period - 1 else { return Double.nan }
            let window = values[(i - period + 1)...i]
            return window.reduce(0, +) / Double(period)
        }
    }

    private static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
