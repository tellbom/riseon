import XCTest
@testable import RiseOn

/// Verifies the collector's per-source degradation contract (task.md's
/// "清晰的降级逻辑、错误记录和数据可用性标记"): one source throwing must not
/// sink the others, and each failure surfaces as a `fetch_failed` status plus
/// a recorded warning.
final class ExternalFactorCollectorTests: XCTestCase {

    private struct StubError: Error {}

    private struct StubCapitalFlow: CapitalFlowProviding {
        var value: [CapitalFlowSnapshot]?
        func fetch(secid: String) async throws -> [CapitalFlowSnapshot] {
            guard let value else { throw StubError() }
            return value
        }
    }
    private struct StubValuation: ValuationProviding {
        var value: ValuationSnapshot?
        func fetch(fullSymbol: String) async throws -> ValuationSnapshot {
            guard let value else { throw StubError() }
            return value
        }
    }
    private struct StubDragonTiger: DragonTigerProviding {
        var value: [DragonTigerRecord]?
        func fetch(code: String) async throws -> [DragonTigerRecord] {
            guard let value else { throw StubError() }
            return value
        }
    }
    private struct StubLimitUp: LimitUpProviding {
        var value: LimitUpStatus?
        func fetch(code: String, dateYYYYMMDD: String) async throws -> LimitUpStatus {
            guard let value else { throw StubError() }
            return value
        }
    }
    private struct StubSector: SectorProviding {
        var value: SectorHeat?
        func fetch(secid: String) async throws -> SectorHeat {
            guard let value else { throw StubError() }
            return value
        }
    }
    private struct StubForecast: FundamentalForecastProviding {
        var throwsError = false
        var value: (type: String?, summary: String?)?
        func fetch(code: String) async throws -> (type: String?, summary: String?)? {
            if throwsError { throw StubError() }
            return value
        }
    }
    private struct StubAnnouncements: AnnouncementProviding {
        var value: [AnnouncementItem]?
        func fetch(code: String) async throws -> [AnnouncementItem] {
            guard let value else { throw StubError() }
            return value
        }
    }

    func test_perSourceDegradation_someFailSomeSucceed() async {
        let collector = ExternalFactorCollector(
            capitalFlowProvider: StubCapitalFlow(value: [CapitalFlowSnapshot(date: "2024-06-03", mainNetInflow: 1_000_000, mainNetInflowRatio: 6)]),
            valuationProvider: StubValuation(value: nil),   // throws -> fetch_failed
            dragonTigerProvider: StubDragonTiger(value: []), // empty is a valid answer -> available
            limitUpProvider: StubLimitUp(value: LimitUpStatus(date: "20240603", isLimitUp: true, boardCount: 2)),
            sectorProvider: StubSector(value: nil),          // throws -> fetch_failed
            forecastProvider: StubForecast(throwsError: true),
            announcementProvider: StubAnnouncements(value: [])
        )

        let bundle = await collector.collect(code: "600519", todayYYYYMMDD: "20240603")

        XCTAssertEqual(bundle.statuses[ContextBlockKey.capitalFlow], .available)
        XCTAssertEqual(bundle.statuses[ContextBlockKey.valuation], .fetchFailed)
        XCTAssertEqual(bundle.statuses[ContextBlockKey.dragonTiger], .available)
        XCTAssertEqual(bundle.statuses[ContextBlockKey.limitUp], .available)
        XCTAssertEqual(bundle.statuses[ContextBlockKey.sector], .fetchFailed)
        // valuation + forecast both failed -> no fundamentals data.
        XCTAssertEqual(bundle.statuses[ContextBlockKey.fundamentals], .fetchFailed)
        XCTAssertEqual(bundle.statuses[ContextBlockKey.announcements], .available)
        // Sentiment still derives from the sources that did succeed.
        XCTAssertEqual(bundle.statuses[ContextBlockKey.sentiment], .available)
        XCTAssertNotNil(bundle.sentiment)

        XCTAssertTrue(bundle.warnings.contains("external_valuation_fetch_failed"))
        XCTAssertTrue(bundle.warnings.contains("external_sector_fetch_failed"))
        XCTAssertEqual(bundle.capitalFlow?.mainNetInflow, 1_000_000)
    }

    func test_unresolvableCode_allMissing_notFetchFailed() async {
        let collector = ExternalFactorCollector(
            capitalFlowProvider: StubCapitalFlow(value: []),
            valuationProvider: StubValuation(value: ValuationSnapshot(turnoverRate: 1)),
            dragonTigerProvider: StubDragonTiger(value: []),
            limitUpProvider: StubLimitUp(value: LimitUpStatus(date: "20240603")),
            sectorProvider: StubSector(value: SectorHeat(industryName: "x")),
            forecastProvider: StubForecast(),
            announcementProvider: StubAnnouncements(value: [])
        )

        let bundle = await collector.collect(code: "BAD", todayYYYYMMDD: "20240603")

        XCTAssertEqual(bundle.statuses[ContextBlockKey.capitalFlow], .missing)
        XCTAssertEqual(bundle.statuses[ContextBlockKey.valuation], .missing)
        XCTAssertTrue(bundle.warnings.contains("external_code_unresolved"))
        XCTAssertNil(bundle.capitalFlow)
    }
}
