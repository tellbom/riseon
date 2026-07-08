import Foundation

/// Turns raw `ContextPack` item keys/values into labeled, unit-bearing,
/// human-readable lines for the LLM prompt — the fix for "数据平铺太粗暴":
/// instead of `- main_net_inflow：1234567.0`, the model sees
/// `- 主力净流入：+123.5万元`, with the口径 (unit / sign / scale) made
/// explicit so it can't misread 元 as 万 or a ratio as an absolute.
///
/// Presentation-only: it reads the same values `ContextPackBuilder` already
/// wrote and never changes the pack, the data flow, or the numbers — only how
/// they're phrased. Unknown keys fall back to the raw key + value so nothing
/// is ever silently dropped.
enum PromptFieldFormatting {

    enum Kind {
        case signedMoney   // 元, show +/- (net flows)
        case money         // 元, unsigned (seal amounts, turnover value)
        case yiYuan        // already denominated in 亿元
        case percent       // append %
        case signedPercent // append %, show +/-
        case fractionPercent // 0–1 fraction -> ×100 + %
        case ratioX        // "倍" (volume ratio)
        case price         // 元, 2 decimals (MA / levels / prices)
        case count(String) // integer + unit suffix (根/天/连板/次/条…)
        case score         // "xx/100"
        case yesNo         // bool -> 是/否
        case text          // pass through string
    }

    struct Spec {
        let label: String
        let kind: Kind
        /// Lower renders first within its block (short-term-relevant fields
        /// float to the top; slow/valuation fields sink).
        let priority: Int
    }

    /// Global key -> spec. Keys are shared across blocks where meaning is
    /// identical (e.g. `main_net_inflow` in both `capital_flow` and `sector`).
    static let specs: [String: Spec] = [
        // quote
        "price": Spec(label: "最新价", kind: .price, priority: 0),
        "change_percent": Spec(label: "涨跌幅", kind: .signedPercent, priority: 1),
        "change_amount": Spec(label: "涨跌额", kind: .signedMoney, priority: 2),
        "open": Spec(label: "今开", kind: .price, priority: 5),
        "high": Spec(label: "最高", kind: .price, priority: 6),
        "low": Spec(label: "最低", kind: .price, priority: 7),
        "previous_close": Spec(label: "昨收", kind: .price, priority: 8),
        // daily_bars
        "latest_date": Spec(label: "最新交易日", kind: .text, priority: 0),
        "latest_close": Spec(label: "最新收盘", kind: .price, priority: 1),
        "count": Spec(label: "样本数", kind: .count("根"), priority: 9),
        // technical
        "signal_score": Spec(label: "规则评分", kind: .score, priority: 0),
        "buy_signal": Spec(label: "规则信号", kind: .text, priority: 1),
        "trend_status": Spec(label: "趋势", kind: .text, priority: 2),
        "macd_status": Spec(label: "MACD状态", kind: .text, priority: 3),
        "rsi_status": Spec(label: "RSI状态", kind: .text, priority: 4),
        "ma5": Spec(label: "MA5", kind: .price, priority: 10),
        "ma10": Spec(label: "MA10", kind: .price, priority: 11),
        "ma20": Spec(label: "MA20", kind: .price, priority: 12),
        "ma60": Spec(label: "MA60", kind: .price, priority: 13),
        "rsi6": Spec(label: "RSI6", kind: .price, priority: 14),
        "rsi12": Spec(label: "RSI12", kind: .price, priority: 15),
        "rsi24": Spec(label: "RSI24", kind: .price, priority: 16),
        "macd_dif": Spec(label: "DIF", kind: .price, priority: 17),
        "macd_dea": Spec(label: "DEA", kind: .price, priority: 18),
        "macd_bar": Spec(label: "MACD柱", kind: .price, priority: 19),
        "macd_golden_cross": Spec(label: "MACD金叉", kind: .yesNo, priority: 20),
        "macd_dead_cross": Spec(label: "MACD死叉", kind: .yesNo, priority: 21),
        "kdj_overbought": Spec(label: "KDJ超买", kind: .yesNo, priority: 22),
        "kdj_oversold": Spec(label: "KDJ超卖", kind: .yesNo, priority: 23),
        // factors
        "return_1d_pct": Spec(label: "1日涨跌", kind: .signedPercent, priority: 0),
        "return_3d_pct": Spec(label: "3日涨跌", kind: .signedPercent, priority: 1),
        "return_5d_pct": Spec(label: "5日涨跌", kind: .signedPercent, priority: 2),
        "return_10d_pct": Spec(label: "10日涨跌", kind: .signedPercent, priority: 3),
        "return_20d_pct": Spec(label: "20日涨跌", kind: .signedPercent, priority: 4),
        "range_position_20d": Spec(label: "20日区间位置", kind: .fractionPercent, priority: 5),
        // levels
        "support_levels": Spec(label: "支撑位", kind: .price, priority: 0),
        "resistance_levels": Spec(label: "阻力位", kind: .price, priority: 1),
        "stop_loss_fallback": Spec(label: "止损回退参考", kind: .price, priority: 2),
        // valuation
        "turnover_rate": Spec(label: "换手率", kind: .percent, priority: 0),
        "volume_ratio": Spec(label: "量比", kind: .ratioX, priority: 1),
        "pe_ttm": Spec(label: "市盈率TTM", kind: .ratioX, priority: 5),
        "pb": Spec(label: "市净率", kind: .ratioX, priority: 6),
        "total_market_cap": Spec(label: "总市值", kind: .yiYuan, priority: 7),
        "float_market_cap": Spec(label: "流通市值", kind: .yiYuan, priority: 8),
        // capital_flow
        "main_net_inflow": Spec(label: "主力净流入", kind: .signedMoney, priority: 0),
        "consecutive_net_inflow_days": Spec(label: "连续净流入", kind: .count("天"), priority: 1),
        "main_net_inflow_ratio": Spec(label: "主力净占比", kind: .signedPercent, priority: 2),
        "super_large_net": Spec(label: "超大单净额", kind: .signedMoney, priority: 3),
        "large_net": Spec(label: "大单净额", kind: .signedMoney, priority: 4),
        "medium_net": Spec(label: "中单净额", kind: .signedMoney, priority: 5),
        "small_net": Spec(label: "小单净额", kind: .signedMoney, priority: 6),
        // dragon_tiger
        "recent_records": Spec(label: "近期上榜次数", kind: .count("次"), priority: 0),
        "latest_explanation": Spec(label: "最近上榜原因", kind: .text, priority: 1),
        "latest_net_buy": Spec(label: "最近龙虎榜净买", kind: .signedMoney, priority: 2),
        // limit_up
        "is_limit_up": Spec(label: "今日涨停", kind: .yesNo, priority: 0),
        "is_limit_down": Spec(label: "今日跌停", kind: .yesNo, priority: 1),
        "board_count": Spec(label: "连板数", kind: .count("连板"), priority: 2),
        "open_times": Spec(label: "炸板次数", kind: .count("次"), priority: 3),
        "first_seal_time": Spec(label: "首封时间", kind: .text, priority: 4),
        "industry": Spec(label: "所属行业", kind: .text, priority: 5),
        // sector
        "industry_name": Spec(label: "所属板块", kind: .text, priority: 0),
        "change_pct": Spec(label: "板块涨跌幅", kind: .signedPercent, priority: 1),
        // fundamentals
        "forecast_type": Spec(label: "业绩预告", kind: .text, priority: 0),
        "forecast_summary": Spec(label: "预告摘要", kind: .text, priority: 1),
        // announcements
        "item_1": Spec(label: "公告1", kind: .text, priority: 1),
        "item_2": Spec(label: "公告2", kind: .text, priority: 2),
        "item_3": Spec(label: "公告3", kind: .text, priority: 3),
        "item_4": Spec(label: "公告4", kind: .text, priority: 4),
        "item_5": Spec(label: "公告5", kind: .text, priority: 5),
        // sentiment
        "score": Spec(label: "情绪热度", kind: .score, priority: 0),
        "label": Spec(label: "情绪档位", kind: .text, priority: 1),
        "drivers": Spec(label: "情绪构成", kind: .text, priority: 2),
    ]

    /// One rendered `- 标签：值` line. Falls back to the raw key + value for
    /// keys with no spec, so new/unknown fields still appear.
    static func line(key: String, value: JSONValue) -> String {
        guard let spec = specs[key] else {
            return "- \(key)：\(rawRendering(value))"
        }
        return "- \(spec.label)：\(format(value, kind: spec.kind))"
    }

    /// Sort key for a block's items: (priority, key) so short-term-relevant
    /// fields lead and unknown keys (priority 999) trail, deterministically.
    static func sortIndex(_ key: String) -> Int {
        specs[key]?.priority ?? 999
    }

    // MARK: - Value formatting

    private static func format(_ value: JSONValue, kind: Kind) -> String {
        switch kind {
        case .signedMoney: return money(value, signed: true)
        case .money: return money(value, signed: false)
        case .yiYuan:
            guard let d = double(value) else { return rawRendering(value) }
            return trim(d) + "亿元"
        case .percent:
            guard let d = double(value) else { return rawRendering(value) }
            return trim(d) + "%"
        case .signedPercent:
            guard let d = double(value) else { return rawRendering(value) }
            return sign(d) + trim(abs(d)) + "%"
        case .fractionPercent:
            guard let d = double(value) else { return rawRendering(value) }
            return trim(d * 100) + "%"
        case .ratioX:
            guard let d = double(value) else { return rawRendering(value) }
            return trim(d)
        case .price:
            if case .array(let arr) = value {
                let parts = arr.compactMap { double($0).map { trim($0) } }
                return parts.isEmpty ? "无" : parts.joined(separator: " / ")
            }
            guard let d = double(value) else { return rawRendering(value) }
            return trim(d)
        case .count(let unit):
            guard let d = double(value) else { return rawRendering(value) }
            return String(Int(d)) + unit
        case .score:
            guard let d = double(value) else { return rawRendering(value) }
            return String(Int(d)) + "/100"
        case .yesNo:
            if case .bool(let b) = value { return b ? "是" : "否" }
            return rawRendering(value)
        case .text:
            return rawRendering(value)
        }
    }

    /// 元 -> auto 万元/亿元 with optional leading sign.
    private static func money(_ value: JSONValue, signed: Bool) -> String {
        guard let d = double(value) else { return rawRendering(value) }
        let prefix = signed ? sign(d) : ""
        let a = abs(d)
        if a >= 1e8 { return prefix + trim(a / 1e8) + "亿元" }
        if a >= 1e4 { return prefix + trim(a / 1e4) + "万元" }
        return prefix + trim(a) + "元"
    }

    private static func sign(_ d: Double) -> String {
        if d > 0 { return "+" }
        if d < 0 { return "-" }
        return ""
    }

    /// Up to 2 decimals, trailing zeros stripped ("10.50" -> "10.5", "10.0" -> "10").
    private static func trim(_ d: Double) -> String {
        let rounded = (d * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return trimTrailingZeros(String(format: "%.2f", rounded))
    }

    private static func trimTrailingZeros(_ s: String) -> String {
        guard s.contains(".") else { return s }
        var out = s
        while out.hasSuffix("0") { out.removeLast() }
        if out.hasSuffix(".") { out.removeLast() }
        return out
    }

    private static func double(_ value: JSONValue) -> Double? {
        switch value {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    private static func rawRendering(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return trim(d)
        case .bool(let b): return b ? "是" : "否"
        case .null: return "无"
        case .array(let arr): return arr.map { rawRendering($0) }.joined(separator: " / ")
        case .object(let o): return o.keys.sorted().map { "\($0): \(rawRendering(o[$0]!))" }.joined(separator: ", ")
        }
    }
}
