import Foundation

/// Swift rewrite of `technical_indicators.py` (task.md S6.1-S6.2, plan.md §8),
/// plus the Wilder's-EMA RSI decision from §0.5-2 (this file's own RSI is
/// already Wilder — `technical_indicators.py`'s original simple-average RSI
/// is intentionally *not* ported here at all, per §0.5-2's "禁用").
///
/// Pure functions, no I/O — this is the `Analytics/` "纪律" from plan.md §6/§13.
///
/// MA/RSI independence note (§0.5-6): `RuleScoreEngine` (S7) needs its own,
/// separately-implemented MA (full-window, `stock_analyzer.py::_calculate_mas`
/// semantics — NaN under the period, MA60 falls back to MA20 under 60 bars),
/// because that differs numerically from this file's `min_periods=1` MA. RSI
/// is different: both `stock_analyzer.py` and this file are required to use
/// the *same* Wilder's-EMA formula (§0.5-2), so unlike MA, there's no
/// numerical divergence to protect against — `RuleScoreEngine` reusing
/// `TechnicalIndicators.rsiWilder` when S7 is built is fine and encouraged,
/// not a violation of §0.5-6 (which is specifically about the MA mismatch).
public enum TechnicalIndicators {

    // MARK: - Series result

    /// One row per input bar, mirroring `calculate_all_indicators`'s added
    /// columns. Values that pandas would leave as `NaN` (e.g. `BOLL_UPPER`
    /// on the very first bar, where a sample stddev needs ≥2 points) are
    /// `Double.nan` here too — check `.isNaN` before using, same as you'd
    /// check `pd.isna(...)` on the Python side.
    public struct Series: Equatable, Sendable {
        public var ma5: [Double]
        public var ma10: [Double]
        public var ma20: [Double]
        public var ma60: [Double]
        public var dif: [Double]
        public var dea: [Double]
        public var macd: [Double]
        public var k: [Double]
        public var d: [Double]
        public var j: [Double]
        public var rsi6: [Double]
        public var rsi12: [Double]
        public var rsi24: [Double]
        public var bollUpper: [Double]
        public var bollMid: [Double]
        public var bollLower: [Double]
    }

    /// Runs every indicator over `bars` at once, mirroring
    /// `calculate_all_indicators`. `bars` must already be ascending by date
    /// (same convention as `TencentDailyProvider`'s output).
    public static func computeAll(bars: [DailyBar]) -> Series {
        let closes = bars.map(\.close)
        let highs = bars.map(\.high)
        let lows = bars.map(\.low)

        let mas = movingAverages(closes: closes)
        let (dif, dea, macdHist) = macd(closes: closes)
        let (k, d, j) = kdj(highs: highs, lows: lows, closes: closes)
        let (upper, mid, lower) = bollingerBands(closes: closes)

        return Series(
            ma5: mas[5] ?? [],
            ma10: mas[10] ?? [],
            ma20: mas[20] ?? [],
            ma60: mas[60] ?? [],
            dif: dif,
            dea: dea,
            macd: macdHist,
            k: k,
            d: d,
            j: j,
            rsi6: rsiWilder(closes: closes, period: 6),
            rsi12: rsiWilder(closes: closes, period: 12),
            rsi24: rsiWilder(closes: closes, period: 24),
            bollUpper: upper,
            bollMid: mid,
            bollLower: lower
        )
    }

    // MARK: - MA (technical_indicators.py::calculate_ma — min_periods=1)

    /// `rolling(window=period, min_periods=1).mean()` for each requested
    /// period: near the start of the series, where fewer than `period` bars
    /// exist yet, the average is taken over however many are actually
    /// available — it does **not** wait for a full window like
    /// `RuleScoreEngine`'s MA will (§0.5-6).
    public static func movingAverages(closes: [Double], periods: [Int] = [5, 10, 20, 60]) -> [Int: [Double]] {
        var result: [Int: [Double]] = [:]
        for period in periods {
            result[period] = rollingMeanMinPeriods1(closes, period: period)
        }
        return result
    }

    // MARK: - MACD(12,26,9)

    public static func macd(
        closes: [Double],
        fast: Int = 12,
        slow: Int = 26,
        signal: Int = 9
    ) -> (dif: [Double], dea: [Double], macd: [Double]) {
        let emaFast = emaSpan(closes, span: fast)
        let emaSlow = emaSpan(closes, span: slow)
        let dif = zip(emaFast, emaSlow).map { fastValue, slowValue in fastValue - slowValue }
        let dea = emaSpan(dif, span: signal)
        let macdHist = zip(dif, dea).map { d, e in (d - e) * 2 }
        return (dif, dea, macdHist)
    }

    // MARK: - KDJ(9,3,3)

    public static func kdj(
        highs: [Double],
        lows: [Double],
        closes: [Double],
        n: Int = 9,
        m1: Int = 3,
        m2: Int = 3
    ) -> (k: [Double], d: [Double], j: [Double]) {
        let count = closes.count
        guard count > 0 else { return ([], [], []) }

        var rsv = [Double](repeating: 50, count: count)
        for i in 0..<count {
            let start = max(0, i - n + 1)
            let lowMin = lows[start...i].min() ?? lows[i]
            let highMax = highs[start...i].max() ?? highs[i]
            if highMax > lowMin {
                rsv[i] = (closes[i] - lowMin) / (highMax - lowMin) * 100
            }
            // else: leave at the fillna(50) default, matching Python's
            // `rsv.fillna(50)` for the degenerate high==low case.
        }

        // com = m1-1 / m2-1 => alpha = 1/(1+com) = 1/m1, 1/m2.
        let k = ema(rsv, alpha: 1.0 / Double(m1))
        let d = ema(k, alpha: 1.0 / Double(m2))
        let j = zip(k, d).map { kValue, dValue in 3 * kValue - 2 * dValue }
        return (k, d, j)
    }

    // MARK: - RSI(6,12,24) — Wilder's EMA (stock_analyzer.py::_calculate_rsi)

    /// Wilder's-EMA RSI: `avg_gain`/`avg_loss` are `ewm(alpha=1/period,
    /// adjust=False)`, not a simple rolling mean. This is the **only** RSI
    /// in this codebase — `technical_indicators.py`'s simple-average version
    /// is banned per §0.5-2 and was never ported.
    public static func rsiWilder(closes: [Double], period: Int) -> [Double] {
        let count = closes.count
        guard count > 0 else { return [] }

        var gains = [Double](repeating: 0, count: count)
        var losses = [Double](repeating: 0, count: count)
        for i in 1..<count {
            let delta = closes[i] - closes[i - 1]
            gains[i] = delta > 0 ? delta : 0
            losses[i] = delta < 0 ? -delta : 0
        }
        // index 0 has no prior close (pandas' `.diff()` gives NaN there,
        // and `.where(delta > 0, 0)` maps that to 0) — already satisfied by
        // the `repeating: 0` initialization above.

        let avgGain = ema(gains, alpha: 1.0 / Double(period))
        let avgLoss = ema(losses, alpha: 1.0 / Double(period))

        return (0..<count).map { i in
            let rs = avgGain[i] / avgLoss[i] // may be `inf` or `nan` — same as pandas' float division
            let value = 100 - 100 / (1 + rs)
            return value.isNaN ? 50 : value    // mirrors Python's `.fillna(50)`
        }
    }

    // MARK: - BOLL(20,2)

    public static func bollingerBands(
        closes: [Double],
        period: Int = 20,
        stdMultiplier: Double = 2
    ) -> (upper: [Double], mid: [Double], lower: [Double]) {
        let mid = rollingMeanMinPeriods1(closes, period: period)
        let std = rollingStdMinPeriods1(closes, period: period)
        let upper = zip(mid, std).map { m, s in m + stdMultiplier * s }
        let lower = zip(mid, std).map { m, s in m - stdMultiplier * s }
        return (upper, mid, lower)
    }

    // MARK: - Shared math helpers

    /// `rolling(window: period, min_periods: 1).mean()`.
    private static func rollingMeanMinPeriods1(_ values: [Double], period: Int) -> [Double] {
        guard !values.isEmpty else { return [] }
        return values.indices.map { i in
            let start = max(0, i - period + 1)
            let window = values[start...i]
            return window.reduce(0, +) / Double(window.count)
        }
    }

    /// `rolling(window: period, min_periods: 1).std()` — pandas' default
    /// (sample stddev, `ddof=1`). Matches pandas exactly in also producing
    /// `NaN` when fewer than 2 observations are available (division by
    /// `count - 1 == 0`), rather than substituting a population stddev.
    private static func rollingStdMinPeriods1(_ values: [Double], period: Int) -> [Double] {
        guard !values.isEmpty else { return [] }
        return values.indices.map { i in
            let start = max(0, i - period + 1)
            let window = values[start...i]
            let count = window.count
            guard count >= 2 else { return Double.nan }
            let mean = window.reduce(0, +) / Double(count)
            let sumSquaredDeviations = window.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
            return (sumSquaredDeviations / Double(count - 1)).squareRoot()
        }
    }

    /// `ewm(alpha: alpha, adjust: false).mean()`: `y[0] = x[0]`,
    /// `y[t] = alpha*x[t] + (1-alpha)*y[t-1]`.
    private static func ema(_ values: [Double], alpha: Double) -> [Double] {
        guard !values.isEmpty else { return [] }
        var result = [Double](repeating: 0, count: values.count)
        result[0] = values[0]
        for i in 1..<values.count {
            result[i] = alpha * values[i] + (1 - alpha) * result[i - 1]
        }
        return result
    }

    /// `ewm(span: span, adjust: false).mean()`, i.e. `alpha = 2/(span+1)`.
    private static func emaSpan(_ values: [Double], span: Int) -> [Double] {
        ema(values, alpha: 2.0 / Double(span + 1))
    }

    // MARK: - Latest signals (S6.2, technical_indicators.py::get_latest_signals)

    /// Boolean signal snapshot for the most recent bar, mirroring
    /// `get_latest_signals`'s dict 1:1 (same 17 keys, same conditions).
    public struct LatestSignals: Equatable, Sendable {
        public var macdGoldenCross: Bool
        public var macdDeadCross: Bool
        public var macdHistogramPositive: Bool
        public var kdjGoldenCross: Bool
        public var kdjDeadCross: Bool
        public var kdjOverbought: Bool
        public var kdjOversold: Bool
        public var rsi6Overbought: Bool
        public var rsi6Oversold: Bool
        public var rsi12Overbought: Bool
        public var rsi12Oversold: Bool
        public var priceAboveUpper: Bool
        public var priceBelowLower: Bool
        public var bollSqueeze: Bool
        public var ma5AboveMa20: Bool
        public var ma10AboveMa20: Bool
        public var priceAboveMa60: Bool
    }

    /// `nil` when `bars` is empty (mirrors `get_latest_signals` returning
    /// `{}` for an empty DataFrame). When there's only one bar, `prev` is the
    /// same bar as `latest` (`prev = df.iloc[-2] if len(df) > 1 else latest`),
    /// which makes the two cross-over signals trivially `false` — same as Python.
    ///
    /// Any comparison against a `NaN` indicator value (e.g. `BOLL_UPPER` on
    /// a very short series) naturally evaluates to `false` in Swift, same as
    /// pandas/NumPy's `NaN` comparison semantics — no special-casing needed.
    public static func latestSignals(bars: [DailyBar], series: Series) -> LatestSignals? {
        guard !bars.isEmpty else { return nil }
        let last = bars.count - 1
        let prev = bars.count > 1 ? bars.count - 2 : last
        let latestClose = bars[last].close

        return LatestSignals(
            macdGoldenCross: series.dif[last] > series.dea[last] && series.dif[prev] <= series.dea[prev],
            macdDeadCross: series.dif[last] < series.dea[last] && series.dif[prev] >= series.dea[prev],
            macdHistogramPositive: series.macd[last] > 0,
            kdjGoldenCross: series.k[last] > series.d[last] && series.k[prev] <= series.d[prev],
            kdjDeadCross: series.k[last] < series.d[last] && series.k[prev] >= series.d[prev],
            kdjOverbought: series.k[last] > 80 && series.d[last] > 80,
            kdjOversold: series.k[last] < 20 && series.d[last] < 20,
            rsi6Overbought: series.rsi6[last] > 80,
            rsi6Oversold: series.rsi6[last] < 20,
            rsi12Overbought: series.rsi12[last] > 70,
            rsi12Oversold: series.rsi12[last] < 30,
            priceAboveUpper: latestClose > series.bollUpper[last],
            priceBelowLower: latestClose < series.bollLower[last],
            bollSqueeze: (series.bollUpper[last] - series.bollLower[last]) / series.bollMid[last] < 0.1,
            ma5AboveMa20: series.ma5[last] > series.ma20[last],
            ma10AboveMa20: series.ma10[last] > series.ma20[last],
            priceAboveMa60: latestClose > series.ma60[last]
        )
    }
}
