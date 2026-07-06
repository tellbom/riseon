import Foundation

/// Swift port of `src/stock_analyzer.py`'s five status enums (task.md S7.1).
/// Raw values keep the exact Chinese labels from the Python `Enum.value`
/// strings, so serialized output matches the Python side 1:1 and any UI
/// text can be lifted directly from `.rawValue`.

/// `TrendStatus` — MA5/MA10/MA20 alignment (`stock_analyzer.py:32-40`).
public enum TrendStatus: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case strongBull = "强势多头"      // MA5 > MA10 > MA20，且间距扩大
    case bull = "多头排列"            // MA5 > MA10 > MA20
    case weakBull = "弱势多头"        // MA5 > MA10，但 MA10 < MA20
    case consolidation = "盘整"       // 均线缠绕
    case weakBear = "弱势空头"        // MA5 < MA10，但 MA10 > MA20
    case bear = "空头排列"            // MA5 < MA10 < MA20
    case strongBear = "强势空头"      // MA5 < MA10 < MA20，且间距扩大
}

/// `VolumeStatus` — volume vs. its trailing 5-day average (`stock_analyzer.py:43-49`).
public enum VolumeStatus: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case heavyVolumeUp = "放量上涨"       // 量价齐升
    case heavyVolumeDown = "放量下跌"     // 放量杀跌
    case shrinkVolumeUp = "缩量上涨"      // 无量上涨
    case shrinkVolumeDown = "缩量回调"    // 缩量回调（好）
    case normal = "量能正常"
}

/// `BuySignal` — the final recommendation (`stock_analyzer.py:52-59`).
public enum BuySignal: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case strongBuy = "强烈买入"    // 多条件满足
    case buy = "买入"              // 基本条件满足
    case hold = "持有"             // 已持有可继续
    case wait = "观望"             // 等待更好时机
    case sell = "卖出"             // 趋势转弱
    case strongSell = "强烈卖出"   // 趋势破坏
}

/// `MACDStatus` (`stock_analyzer.py:62-70`).
public enum MACDStatus: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case goldenCrossZero = "零轴上金叉"   // DIF上穿DEA，且在零轴上方
    case goldenCross = "金叉"            // DIF上穿DEA
    case bullish = "多头"                // DIF>DEA>0
    case crossingUp = "上穿零轴"          // DIF上穿零轴
    case crossingDown = "下穿零轴"        // DIF下穿零轴
    case bearish = "空头"                // DIF<DEA<0
    case deathCross = "死叉"             // DIF下穿DEA
}

/// `RSIStatus` (`stock_analyzer.py:73-79`). NOTE: the thresholds actually
/// used in `_analyze_rsi` (`>70`/`>60`/`>=40`/`>=30`/else) are slightly
/// different from what this enum's Python docstring comments claim
/// (e.g. the comment says "50 < RSI < 70" for `STRONG_BUY`, but the real
/// code branches on `> 60`) — `RuleScoreEngine.analyzeRSI` follows the
/// **code**, not the docstring, and that's the version reflected below.
public enum RSIStatus: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case overbought = "超买"       // 实际判断：RSI(12) > 70
    case strongBuy = "强势买入"    // 实际判断：60 < RSI(12) <= 70
    case neutral = "中性"          // 实际判断：40 <= RSI(12) <= 60
    case weak = "弱势"             // 实际判断：30 <= RSI(12) < 40
    case oversold = "超卖"         // 实际判断：RSI(12) < 30
}
