import XCTest
@testable import RiseOn

/// Covers `ContextPackBuilder`'s external-bundle integration: a present bundle
/// upgrades/adds blocks; an absent bundle preserves the exact MVP baseline
/// (the pre-existing `ContextPackBuilderTests` all run the `nil` path, so this
/// nails down that the nil path is unchanged).
final class ContextPackBuilderExternalTests: XCTestCase {

    private func fullBundle(fundamentals: FundamentalSummary? = FundamentalSummary(peTTM: 25, pb: 8, forecastType: "预增")) -> ExternalFactorBundle {
        let flow = CapitalFlowSnapshot(date: "2024-06-03", mainNetInflow: 1_000_000, mainNetInflowRatio: 6)
        var statuses: [String: ContextFieldStatus] = [
            ContextBlockKey.capitalFlow: .available,
            ContextBlockKey.valuation: .available,
            ContextBlockKey.dragonTiger: .available,
            ContextBlockKey.limitUp: .available,
            ContextBlockKey.sector: .available,
            ContextBlockKey.announcements: .available,
            ContextBlockKey.sentiment: .available,
        ]
        statuses[ContextBlockKey.fundamentals] = fundamentals == nil ? .fetchFailed : .available
        return ExternalFactorBundle(
            capitalFlow: flow,
            capitalFlowHistory: [flow],
            valuation: ValuationSnapshot(turnoverRate: 3.2, volumeRatio: 1.3, peTTM: 25, pb: 8),
            dragonTiger: [DragonTigerRecord(date: "2024-06-03", explanation: "涨幅偏离", netBuy: 5)],
            limitUp: LimitUpStatus(date: "20240603", isLimitUp: true, boardCount: 2),
            sector: SectorHeat(industryName: "白酒", mainNetInflow: 100),
            fundamentals: fundamentals,
            announcements: [AnnouncementItem(title: "公告", date: "2024-07-01")],
            sentiment: SentimentSnapshot(score: 80, label: "过热", drivers: ["涨停"]),
            statuses: statuses,
            warnings: ["external_demo_warning"]
        )
    }

    func test_presentBundle_upgradesAndAddsBlocks() {
        let pack = ContextPackBuilder.build(.init(
            subject: ContextPackSubject(code: "600519"),
            externalBundle: fullBundle()
        ))

        XCTAssertEqual(pack.blocks[ContextBlockKey.capitalFlow]?.status, .available)
        XCTAssertEqual(pack.blocks[ContextBlockKey.capitalFlow]?.items["main_net_inflow"]?.value, .double(1_000_000))
        XCTAssertEqual(pack.blocks[ContextBlockKey.capitalFlow]?.items["consecutive_net_inflow_days"]?.value, .int(1))
        XCTAssertEqual(pack.blocks[ContextBlockKey.valuation]?.status, .available)
        XCTAssertEqual(pack.blocks[ContextBlockKey.valuation]?.items["pe_ttm"]?.value, .double(25))
        XCTAssertEqual(pack.blocks[ContextBlockKey.dragonTiger]?.status, .available)
        XCTAssertEqual(pack.blocks[ContextBlockKey.limitUp]?.items["board_count"]?.value, .int(2))
        XCTAssertEqual(pack.blocks[ContextBlockKey.sector]?.items["industry_name"]?.value, .string("白酒"))
        XCTAssertEqual(pack.blocks[ContextBlockKey.sentiment]?.items["label"]?.value, .string("过热"))
        // fundamentals upgraded from the not_supported baseline.
        XCTAssertEqual(pack.blocks[ContextBlockKey.fundamentals]?.status, .available)
        XCTAssertEqual(pack.blocks[ContextBlockKey.fundamentals]?.items["forecast_type"]?.value, .string("预增"))
        // bundle warnings threaded into data quality.
        XCTAssertTrue(pack.dataQuality.warnings.contains("external_demo_warning"))
    }

    func test_nilBundle_preservesMVPBaseline() {
        let pack = ContextPackBuilder.build(.init(subject: ContextPackSubject(code: "600519")))

        XCTAssertEqual(pack.blocks[ContextBlockKey.capitalFlow]?.status, .notSupported)
        XCTAssertEqual(pack.blocks[ContextBlockKey.fundamentals]?.status, .notSupported)
        // Extra external blocks are not added at all on the nil path.
        XCTAssertNil(pack.blocks[ContextBlockKey.valuation])
        XCTAssertNil(pack.blocks[ContextBlockKey.dragonTiger])
        XCTAssertNil(pack.blocks[ContextBlockKey.limitUp])
        XCTAssertNil(pack.blocks[ContextBlockKey.sector])
        XCTAssertNil(pack.blocks[ContextBlockKey.announcements])
        XCTAssertNil(pack.blocks[ContextBlockKey.sentiment])
    }

    func test_failedFundamentals_fallsBackToNotSupported_notFetchFailed() {
        // A flaky external fundamentals fetch must not drop the weighted
        // quality block below the MVP not_supported floor.
        let pack = ContextPackBuilder.build(.init(
            subject: ContextPackSubject(code: "600519"),
            externalBundle: fullBundle(fundamentals: nil)
        ))
        XCTAssertEqual(pack.blocks[ContextBlockKey.fundamentals]?.status, .notSupported)
        // But an unweighted source (capital flow) can honestly stay available.
        XCTAssertEqual(pack.blocks[ContextBlockKey.capitalFlow]?.status, .available)
    }
}
