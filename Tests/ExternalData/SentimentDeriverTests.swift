import XCTest
@testable import RiseOn

final class SentimentDeriverTests: XCTestCase {

    func test_hotSignals_produceHighScore() {
        let sentiment = SentimentDeriver.derive(
            limitUp: LimitUpStatus(date: "20240603", isLimitUp: true, boardCount: 2),
            dragonTiger: [DragonTigerRecord(date: "2024-06-03", netBuy: 5_000_000)],
            valuation: ValuationSnapshot(turnoverRate: 20, volumeRatio: 2.5),
            capitalFlow: CapitalFlowSnapshot(date: "2024-06-03", mainNetInflow: 1_000_000, mainNetInflowRatio: 6)
        )
        XCTAssertNotNil(sentiment)
        XCTAssertGreaterThan(sentiment!.score, 75)
        XCTAssertEqual(sentiment!.label, "过热")
        XCTAssertTrue(sentiment!.drivers.contains { $0.contains("涨停") })
    }

    func test_limitDown_producesLowScore() {
        let sentiment = SentimentDeriver.derive(
            limitUp: LimitUpStatus(date: "20240603", isLimitDown: true),
            dragonTiger: [],
            valuation: ValuationSnapshot(volumeRatio: 0.5),
            capitalFlow: CapitalFlowSnapshot(date: "2024-06-03", mainNetInflow: -1_000_000)
        )
        XCTAssertNotNil(sentiment)
        XCTAssertLessThan(sentiment!.score, 35)
        XCTAssertEqual(sentiment!.label, "冷清")
    }

    func test_noInputs_returnsNil() {
        XCTAssertNil(SentimentDeriver.derive(limitUp: nil, dragonTiger: [], valuation: nil, capitalFlow: nil))
    }

    func test_labelBoundaries() {
        XCTAssertEqual(SentimentDeriver.label(for: 34), "冷清")
        XCTAssertEqual(SentimentDeriver.label(for: 35), "中性")
        XCTAssertEqual(SentimentDeriver.label(for: 54), "中性")
        XCTAssertEqual(SentimentDeriver.label(for: 55), "活跃")
        XCTAssertEqual(SentimentDeriver.label(for: 74), "活跃")
        XCTAssertEqual(SentimentDeriver.label(for: 75), "过热")
    }
}
