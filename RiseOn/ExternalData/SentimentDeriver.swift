import Foundation

/// Derives an on-device 情绪面 score — **no external source** (feasibility
/// review: A-share sentiment data has no stable public端上 endpoint; the
/// signal is instead synthesized from dimensions already fetched — 涨停连板、
/// 龙虎榜、换手率/量比、主力资金流). Pure function, unit-testable.
public enum SentimentDeriver {
    /// Composite 0–100 heat score. Neutral baseline 45; each dimension nudges
    /// it. Weights are deliberately simple and documented rather than tuned —
    /// this is a coarse "冷/温/热/过热" gauge for the LLM context, not a
    /// calibrated factor.
    public static func derive(
        limitUp: LimitUpStatus?,
        dragonTiger: [DragonTigerRecord],
        valuation: ValuationSnapshot?,
        capitalFlow: CapitalFlowSnapshot?
    ) -> SentimentSnapshot? {
        // Nothing to derive from → no sentiment (caller marks the block missing).
        if limitUp == nil && dragonTiger.isEmpty && valuation == nil && capitalFlow == nil {
            return nil
        }

        var score = 45.0
        var drivers: [String] = []

        if let limitUp {
            if limitUp.isLimitUp {
                let boards = limitUp.boardCount ?? 1
                let bonus = 18.0 + Double(min(boards, 5)) * 4.0
                score += bonus
                drivers.append("涨停" + (boards > 1 ? "（\(boards)连板）" : ""))
            } else if limitUp.isLimitDown {
                score -= 25.0
                drivers.append("跌停")
            }
        }

        if let latest = dragonTiger.first {
            if let net = latest.netBuy {
                if net > 0 { score += 8; drivers.append("龙虎榜净买入") }
                else if net < 0 { score -= 6; drivers.append("龙虎榜净卖出") }
            } else {
                score += 4
                drivers.append("近期上龙虎榜")
            }
        }

        if let turnover = valuation?.turnoverRate {
            if turnover > 15 { score += 10; drivers.append("换手率极高") }
            else if turnover > 8 { score += 6; drivers.append("换手率偏高") }
            else if turnover > 3 { score += 2 }
        }

        if let volumeRatio = valuation?.volumeRatio {
            if volumeRatio > 2 { score += 8; drivers.append("量比放大") }
            else if volumeRatio > 1.5 { score += 4 }
            else if volumeRatio < 0.7 { score -= 4; drivers.append("量能萎缩") }
        }

        if let flow = capitalFlow {
            if flow.mainNetInflow > 0 {
                score += 6
                if (flow.mainNetInflowRatio ?? 0) > 5 { score += 4 }
                drivers.append("主力净流入")
            } else if flow.mainNetInflow < 0 {
                score -= 6
                drivers.append("主力净流出")
            }
        }

        let clamped = Int(max(0, min(100, score)).rounded())
        return SentimentSnapshot(score: clamped, label: label(for: clamped), drivers: drivers)
    }

    public static func label(for score: Int) -> String {
        if score < 35 { return "冷清" }
        if score < 55 { return "中性" }
        if score < 75 { return "活跃" }
        return "过热"
    }
}
