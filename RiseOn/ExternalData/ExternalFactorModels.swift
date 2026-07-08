import Foundation

/// On-device external-factor models — the短线量化 data dimensions the MVP
/// left as `not_supported` (plan.md §7/§8) but which the feasibility review
/// confirmed are reachable directly from the phone over public HTTPS JSON
/// endpoints (Tencent `qt.gtimg.cn`, Eastmoney `push2*`/`datacenter-web`,
/// CNInfo `cninfo.com.cn`), with **no server component** — consistent with
/// the app's "离线优先、端上自洽、无服务端依赖" principle.
///
/// Every field is optional / defaulted so a partially-degraded fetch still
/// produces a usable value (the collector marks per-source availability
/// separately in `ExternalFactorBundle.statuses`). Amounts are in 元 unless
/// noted; percentages are in whole-number percent (e.g. `3.2` == 3.2%).

/// 主力资金流（单日快照，来自东财 `fflow/daykline`）。
public struct CapitalFlowSnapshot: Codable, Equatable, Hashable, Sendable {
    public var date: String
    public var mainNetInflow: Double        // 主力净流入额（元）
    public var mainNetInflowRatio: Double?  // 主力净占比（%）
    public var superLargeNet: Double?       // 超大单净额
    public var largeNet: Double?            // 大单净额
    public var mediumNet: Double?           // 中单净额
    public var smallNet: Double?            // 小单净额
    public var close: Double?
    public var changePct: Double?

    public init(
        date: String,
        mainNetInflow: Double,
        mainNetInflowRatio: Double? = nil,
        superLargeNet: Double? = nil,
        largeNet: Double? = nil,
        mediumNet: Double? = nil,
        smallNet: Double? = nil,
        close: Double? = nil,
        changePct: Double? = nil
    ) {
        self.date = date
        self.mainNetInflow = mainNetInflow
        self.mainNetInflowRatio = mainNetInflowRatio
        self.superLargeNet = superLargeNet
        self.largeNet = largeNet
        self.mediumNet = mediumNet
        self.smallNet = smallNet
        self.close = close
        self.changePct = changePct
    }
}

/// 估值/交易面快照（换手率、量比、PE/PB、市值），来自腾讯行情行。
public struct ValuationSnapshot: Codable, Equatable, Hashable, Sendable {
    public var turnoverRate: Double?   // 换手率（%）
    public var volumeRatio: Double?    // 量比
    public var peTTM: Double?          // 市盈率 TTM
    public var pb: Double?             // 市净率
    public var totalMarketCap: Double? // 总市值（亿元）
    public var floatMarketCap: Double? // 流通市值（亿元）

    public init(
        turnoverRate: Double? = nil,
        volumeRatio: Double? = nil,
        peTTM: Double? = nil,
        pb: Double? = nil,
        totalMarketCap: Double? = nil,
        floatMarketCap: Double? = nil
    ) {
        self.turnoverRate = turnoverRate
        self.volumeRatio = volumeRatio
        self.peTTM = peTTM
        self.pb = pb
        self.totalMarketCap = totalMarketCap
        self.floatMarketCap = floatMarketCap
    }

    /// True only if at least one field parsed — the collector treats an
    /// all-nil snapshot as "fetched but empty" rather than available.
    public var hasAnyValue: Bool {
        turnoverRate != nil || volumeRatio != nil || peTTM != nil
            || pb != nil || totalMarketCap != nil || floatMarketCap != nil
    }
}

/// 龙虎榜单条记录（来自东财 datacenter `RPT_DAILYBILLBOARD_DETAILSNEW`）。
public struct DragonTigerRecord: Codable, Equatable, Hashable, Sendable {
    public var date: String
    public var explanation: String?  // 上榜原因
    public var netBuy: Double?       // 龙虎榜净买额
    public var buyAmount: Double?
    public var sellAmount: Double?
    public var turnoverRate: Double?

    public init(
        date: String,
        explanation: String? = nil,
        netBuy: Double? = nil,
        buyAmount: Double? = nil,
        sellAmount: Double? = nil,
        turnoverRate: Double? = nil
    ) {
        self.date = date
        self.explanation = explanation
        self.netBuy = netBuy
        self.buyAmount = buyAmount
        self.sellAmount = sellAmount
        self.turnoverRate = turnoverRate
    }
}

/// 涨跌停状态（从东财涨停池/跌停池中过滤本股，来自 `push2ex`）。
public struct LimitUpStatus: Codable, Equatable, Hashable, Sendable {
    public var date: String
    public var isLimitUp: Bool
    public var isLimitDown: Bool
    public var boardCount: Int?      // 连板数
    public var openTimes: Int?       // 炸板次数
    public var firstSealTime: String?  // 首封时间
    public var sealAmount: Double?   // 封单额
    public var industry: String?     // 所属行业

    public init(
        date: String,
        isLimitUp: Bool = false,
        isLimitDown: Bool = false,
        boardCount: Int? = nil,
        openTimes: Int? = nil,
        firstSealTime: String? = nil,
        sealAmount: Double? = nil,
        industry: String? = nil
    ) {
        self.date = date
        self.isLimitUp = isLimitUp
        self.isLimitDown = isLimitDown
        self.boardCount = boardCount
        self.openTimes = openTimes
        self.firstSealTime = firstSealTime
        self.sealAmount = sealAmount
        self.industry = industry
    }
}

/// 个股所属行业板块及其热度（来自东财 `push2`）。
public struct SectorHeat: Codable, Equatable, Hashable, Sendable {
    public var industryName: String?
    public var mainNetInflow: Double?      // 板块主力净额（元）
    public var mainNetInflowRatio: Double? // 板块主力净占比（%）
    public var changePct: Double?          // 板块涨跌幅（%）

    public init(
        industryName: String? = nil,
        mainNetInflow: Double? = nil,
        mainNetInflowRatio: Double? = nil,
        changePct: Double? = nil
    ) {
        self.industryName = industryName
        self.mainNetInflow = mainNetInflow
        self.mainNetInflowRatio = mainNetInflowRatio
        self.changePct = changePct
    }

    public var hasAnyValue: Bool {
        industryName != nil || mainNetInflow != nil
            || mainNetInflowRatio != nil || changePct != nil
    }
}

/// 基本面摘要（估值 + 业绩预告），来自腾讯行情 + 东财 datacenter。
public struct FundamentalSummary: Codable, Equatable, Hashable, Sendable {
    public var peTTM: Double?
    public var pb: Double?
    public var totalMarketCap: Double?  // 亿元
    public var forecastType: String?    // 业绩预告类型（预增/预减/扭亏…）
    public var forecastSummary: String? // 业绩预告摘要

    public init(
        peTTM: Double? = nil,
        pb: Double? = nil,
        totalMarketCap: Double? = nil,
        forecastType: String? = nil,
        forecastSummary: String? = nil
    ) {
        self.peTTM = peTTM
        self.pb = pb
        self.totalMarketCap = totalMarketCap
        self.forecastType = forecastType
        self.forecastSummary = forecastSummary
    }

    public var hasAnyValue: Bool {
        peTTM != nil || pb != nil || totalMarketCap != nil
            || forecastType != nil || forecastSummary != nil
    }
}

/// 公告事件（来自巨潮 CNInfo）。
public struct AnnouncementItem: Codable, Equatable, Hashable, Sendable {
    public var title: String
    public var date: String
    public var type: String?
    public var url: String?

    public init(title: String, date: String, type: String? = nil, url: String? = nil) {
        self.title = title
        self.date = date
        self.type = type
        self.url = url
    }
}

/// 情绪面快照 —— **端上自算**，不依赖独立数据源（研究结论：情绪由涨停连板、
/// 龙虎榜、换手率/量比、资金流等已有维度衍生）。见 `SentimentDeriver`。
public struct SentimentSnapshot: Codable, Equatable, Hashable, Sendable {
    public var score: Int          // 0-100 综合热度
    public var label: String       // 冷清 / 中性 / 活跃 / 过热
    public var drivers: [String]   // 可读的构成说明

    public init(score: Int, label: String, drivers: [String] = []) {
        self.score = score
        self.label = label
        self.drivers = drivers
    }
}

/// 单只股票的一整包外部因子 + 逐源可用性。`statuses` 用 `ContextBlockKey`
/// 的块名做 key（`capital_flow`/`valuation`/…），值为 `ContextFieldStatus`——
/// 直接对齐 ContextPack 的状态语义，`ContextPackBuilder` 据此决定每个块落成
/// `available`/`partial`/`fetch_failed`/`missing`，不写死单一数据源。
public struct ExternalFactorBundle: Codable, Equatable, Hashable, Sendable {
    public var capitalFlow: CapitalFlowSnapshot?
    /// 最近若干日主力资金流序列（用于趋势/连续净流入判断）。
    public var capitalFlowHistory: [CapitalFlowSnapshot]
    public var valuation: ValuationSnapshot?
    public var dragonTiger: [DragonTigerRecord]
    public var limitUp: LimitUpStatus?
    public var sector: SectorHeat?
    public var fundamentals: FundamentalSummary?
    public var announcements: [AnnouncementItem]
    public var sentiment: SentimentSnapshot?
    /// 逐块状态（key = ContextBlockKey 块名）。
    public var statuses: [String: ContextFieldStatus]
    /// 汇总告警（如某源限流/失败），最终并入 `data_quality.warnings`。
    public var warnings: [String]

    public init(
        capitalFlow: CapitalFlowSnapshot? = nil,
        capitalFlowHistory: [CapitalFlowSnapshot] = [],
        valuation: ValuationSnapshot? = nil,
        dragonTiger: [DragonTigerRecord] = [],
        limitUp: LimitUpStatus? = nil,
        sector: SectorHeat? = nil,
        fundamentals: FundamentalSummary? = nil,
        announcements: [AnnouncementItem] = [],
        sentiment: SentimentSnapshot? = nil,
        statuses: [String: ContextFieldStatus] = [:],
        warnings: [String] = []
    ) {
        self.capitalFlow = capitalFlow
        self.capitalFlowHistory = capitalFlowHistory
        self.valuation = valuation
        self.dragonTiger = dragonTiger
        self.limitUp = limitUp
        self.sector = sector
        self.fundamentals = fundamentals
        self.announcements = announcements
        self.sentiment = sentiment
        self.statuses = statuses
        self.warnings = warnings
    }
}

extension ACodeResolver.Market {
    /// Eastmoney `secid` market prefix — `{prefix}.{code}` (e.g. `1.600519`).
    /// SH=1, SZ=0, BJ=2 (per the数据源 collectors analyzed in the feasibility
    /// review). A wrong prefix simply yields an empty payload → the source
    /// degrades to `fetch_failed`, never a crash.
    public var eastmoneySecidPrefix: Int {
        switch self {
        case .sh: return 1
        case .sz: return 0
        case .bj: return 2
        }
    }
}
