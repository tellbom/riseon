import Foundation

/// Aggregates every on-device external-factor source into one
/// `ExternalFactorBundle`, marking each source's availability independently
/// (task.md's "如果外部数据源不稳定，需要设计清晰的降级逻辑、错误记录和数据
/// 可用性标记"). A single source throwing never fails the whole collect — it
/// becomes a `fetch_failed` status + a warning, and the rest still populate,
/// mirroring `WorkspaceInitializationCoordinator`'s "network steps never
/// throw, they degrade" discipline.
public protocol ExternalFactorCollecting: Sendable {
    /// - Parameter todayYYYYMMDD: trading-day key for the涨停池 lookup, passed
    ///   in (not read from the clock inside) so it stays deterministic and
    ///   testable — same reasoning as `RealtimeOverlay`/`StalenessEvaluator`
    ///   taking their date/trading-day inputs from the caller.
    func collect(code: String, todayYYYYMMDD: String) async -> ExternalFactorBundle
}

public actor ExternalFactorCollector: ExternalFactorCollecting {
    private let capitalFlowProvider: any CapitalFlowProviding
    private let valuationProvider: any ValuationProviding
    private let dragonTigerProvider: any DragonTigerProviding
    private let limitUpProvider: any LimitUpProviding
    private let sectorProvider: any SectorProviding
    private let forecastProvider: any FundamentalForecastProviding
    private let announcementProvider: any AnnouncementProviding

    public init(
        capitalFlowProvider: any CapitalFlowProviding = EastmoneyCapitalFlowProvider(),
        valuationProvider: any ValuationProviding = TencentValuationProvider(),
        dragonTigerProvider: any DragonTigerProviding = EastmoneyDragonTigerProvider(),
        limitUpProvider: any LimitUpProviding = EastmoneyLimitUpProvider(),
        sectorProvider: any SectorProviding = EastmoneySectorProvider(),
        forecastProvider: any FundamentalForecastProviding = EastmoneyFundamentalForecastProvider(),
        announcementProvider: any AnnouncementProviding = EastmoneyAnnouncementProvider()
    ) {
        self.capitalFlowProvider = capitalFlowProvider
        self.valuationProvider = valuationProvider
        self.dragonTigerProvider = dragonTigerProvider
        self.limitUpProvider = limitUpProvider
        self.sectorProvider = sectorProvider
        self.forecastProvider = forecastProvider
        self.announcementProvider = announcementProvider
    }

    public func collect(code: String, todayYYYYMMDD: String) async -> ExternalFactorBundle {
        guard let market = ACodeResolver.market(for: code),
              let fullSymbol = ACodeResolver.fullSymbol(for: code) else {
            // Structural: can't resolve the code to a market/symbol at all.
            // Not a fetch failure — every external block is simply未获取.
            return ExternalFactorBundle(
                statuses: Self.allBlockKeys.reduce(into: [:]) { $0[$1] = .missing },
                warnings: ["external_code_unresolved"]
            )
        }
        let secid = "\(market.eastmoneySecidPrefix).\(code)"

        // Hoist the (Sendable) providers into locals before the `async let`
        // fan-out, so each child task captures a plain Sendable value rather
        // than reading actor-isolated `self` state from a concurrent context.
        let flowProvider = capitalFlowProvider
        let valProvider = valuationProvider
        let dragonProvider = dragonTigerProvider
        let limitProvider = limitUpProvider
        let sectorProviderLocal = sectorProvider
        let forecastProviderLocal = forecastProvider
        let announceProvider = announcementProvider

        // Fan out — every source runs concurrently, each isolated by `try?`.
        async let flowTask = flowProvider.fetch(secid: secid)
        async let valuationTask = valProvider.fetch(fullSymbol: fullSymbol)
        async let dragonTask = dragonProvider.fetch(code: code)
        async let limitTask = limitProvider.fetch(code: code, dateYYYYMMDD: todayYYYYMMDD)
        async let sectorTask = sectorProviderLocal.fetch(secid: secid)
        async let forecastTask = forecastProviderLocal.fetch(code: code)
        async let announceTask = announceProvider.fetch(code: code)

        let flow = try? await flowTask
        let valuation = try? await valuationTask
        let dragon = try? await dragonTask
        let limit = try? await limitTask
        let sector = try? await sectorTask
        let forecast = (try? await forecastTask) ?? nil
        let announcements = try? await announceTask

        var statuses: [String: ContextFieldStatus] = [:]
        var warnings: [String] = []

        // 主力资金流
        let capitalFlowHistory = flow ?? []
        let latestFlow = capitalFlowHistory.last
        statuses[ContextBlockKey.capitalFlow] = status(for: flow, warnings: &warnings, key: "capital_flow")

        // 换手率/量比/PE/PB/市值
        statuses[ContextBlockKey.valuation] = status(for: valuation, warnings: &warnings, key: "valuation")

        // 龙虎榜（空 = 近期未上榜，也是有效结论）
        statuses[ContextBlockKey.dragonTiger] = status(for: dragon, warnings: &warnings, key: "dragon_tiger")

        // 涨跌停
        statuses[ContextBlockKey.limitUp] = status(for: limit, warnings: &warnings, key: "limit_up")

        // 行业板块热度
        let resolvedSector = sector
        statuses[ContextBlockKey.sector] = sectorStatus(resolvedSector, warnings: &warnings)

        // 基本面摘要（估值 + 业绩预告合并）
        let fundamentals = Self.mergeFundamentals(valuation: valuation, forecast: forecast)
        statuses[ContextBlockKey.fundamentals] = fundamentals.hasAnyValue ? .available : .fetchFailed
        if !fundamentals.hasAnyValue { warnings.append("external_fundamentals_fetch_failed") }

        // 公告（空 = 近期无公告，也是有效结论）
        statuses[ContextBlockKey.announcements] = status(for: announcements, warnings: &warnings, key: "announcements")

        // 情绪面（端上自算）
        let sentiment = SentimentDeriver.derive(
            limitUp: limit,
            dragonTiger: dragon ?? [],
            valuation: valuation,
            capitalFlow: latestFlow
        )
        statuses[ContextBlockKey.sentiment] = sentiment != nil ? .available : .missing

        return ExternalFactorBundle(
            capitalFlow: latestFlow,
            capitalFlowHistory: capitalFlowHistory,
            valuation: valuation,
            dragonTiger: dragon ?? [],
            limitUp: limit,
            sector: resolvedSector,
            fundamentals: fundamentals.hasAnyValue ? fundamentals : nil,
            announcements: announcements ?? [],
            sentiment: sentiment,
            statuses: statuses,
            warnings: warnings
        )
    }

    // MARK: - Status helpers

    /// `nil` (the source threw) → `fetch_failed` + a warning; a non-nil but
    /// empty result → `available` (an empty龙虎榜/公告 list is itself a valid
    /// "近期没有" answer, not a failure).
    private func status<T>(for value: T?, warnings: inout [String], key: String) -> ContextFieldStatus {
        if value == nil {
            warnings.append("external_\(key)_fetch_failed")
            return .fetchFailed
        }
        return .available
    }

    private func sectorStatus(_ sector: SectorHeat?, warnings: inout [String]) -> ContextFieldStatus {
        guard let sector else {
            warnings.append("external_sector_fetch_failed")
            return .fetchFailed
        }
        // Got the归属 name but not the board-heat numbers → partial.
        if sector.industryName != nil && sector.mainNetInflow == nil && sector.changePct == nil {
            return .partial
        }
        return sector.hasAnyValue ? .available : .fetchFailed
    }

    private static func mergeFundamentals(
        valuation: ValuationSnapshot?,
        forecast: (type: String?, summary: String?)?
    ) -> FundamentalSummary {
        FundamentalSummary(
            peTTM: valuation?.peTTM,
            pb: valuation?.pb,
            totalMarketCap: valuation?.totalMarketCap,
            forecastType: forecast?.type,
            forecastSummary: forecast?.summary
        )
    }

    static let allBlockKeys = [
        ContextBlockKey.capitalFlow, ContextBlockKey.valuation, ContextBlockKey.dragonTiger,
        ContextBlockKey.limitUp, ContextBlockKey.sector, ContextBlockKey.fundamentals,
        ContextBlockKey.announcements, ContextBlockKey.sentiment,
    ]
}
