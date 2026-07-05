import XCTest
@testable import RiseOn

/// Covers task.md S2.3's verification point: exact examples from the task,
/// plus a regression comparison against the existing (narrower)
/// `StockSymbol.swift`, which `ACodeResolver` deliberately does not reuse
/// (plan.md §0.5-3).
final class ACodeResolverTests: XCTestCase {

    // MARK: - Exact examples from task.md S2.3

    func test_shanghaiMainBoard_600519() {
        XCTAssertEqual(ACodeResolver.market(for: "600519"), .sh)
        XCTAssertEqual(ACodeResolver.fullSymbol(for: "600519"), "sh600519")
    }

    func test_shenzhenMainBoard_000001() {
        XCTAssertEqual(ACodeResolver.market(for: "000001"), .sz)
        XCTAssertEqual(ACodeResolver.fullSymbol(for: "000001"), "sz000001")
    }

    func test_chiNext_300059() {
        XCTAssertEqual(ACodeResolver.market(for: "300059"), .sz)
        XCTAssertEqual(ACodeResolver.fullSymbol(for: "300059"), "sz300059")
    }

    func test_shanghaiBShare_900xxx_isSH_notBSE() {
        // 900xxx is a Shanghai B-share and must NOT be classified as BSE,
        // even though it starts with "9" like the BSE 92xxxx range.
        XCTAssertFalse(ACodeResolver.isBSECode("900901"))
        XCTAssertEqual(ACodeResolver.market(for: "900901"), .sh)
        XCTAssertEqual(ACodeResolver.fullSymbol(for: "900901"), "sh900901")
    }

    func test_fivePrefix_isSH() {
        XCTAssertEqual(ACodeResolver.market(for: "510300"), .sh)
    }

    func test_ninePrefix_nonBSE_isSH() {
        XCTAssertEqual(ACodeResolver.market(for: "910001"), .sh)
    }

    func test_bseNewFormat_920xxx_isBJ() {
        XCTAssertTrue(ACodeResolver.isBSECode("920748"))
        XCTAssertEqual(ACodeResolver.market(for: "920748"), .bj)
        XCTAssertEqual(ACodeResolver.fullSymbol(for: "920748"), "bj920748")
    }

    func test_bseHistorical_43xxxx_isBJ() {
        XCTAssertTrue(ACodeResolver.isBSECode("430001"))
        XCTAssertEqual(ACodeResolver.market(for: "430001"), .bj)
    }

    func test_allHistoricalBSEPrefixes() {
        for prefix in ["43", "81", "82", "83", "87", "88", "92"] {
            let code = prefix + "0001"
            XCTAssertTrue(ACodeResolver.isBSECode(code), "\(code) should be BSE")
            XCTAssertEqual(ACodeResolver.market(for: code), .bj, "\(code) should resolve to bj")
        }
    }

    // MARK: - Invalid input

    func test_invalidLength_returnsNil() {
        XCTAssertNil(ACodeResolver.market(for: "12345"))
        XCTAssertNil(ACodeResolver.market(for: "1234567"))
    }

    func test_nonNumeric_returnsNil() {
        XCTAssertNil(ACodeResolver.market(for: "60051A"))
        XCTAssertNil(ACodeResolver.market(for: "SH6005"))
    }

    // MARK: - Regression vs. existing StockSymbol.swift (deliberately different)

    func test_regression_stockSymbolRejectsCodesACodeResolverAccepts() {
        // StockSymbol only accepts 0/3/4/6/8-prefixed codes (watchlist UI rule).
        // ACodeResolver additionally accepts 5/9-prefixed codes as `sh`, and
        // resolves 900xxx to `sh` (not `bj`) unlike a naive "starts with 9/8/4" rule.
        let onlyACodeResolverHandles = ["510300", "900901", "910001"]
        for code in onlyACodeResolverHandles {
            XCTAssertNil(StockSymbol(code: code), "StockSymbol should still reject \(code)")
            XCTAssertNotNil(ACodeResolver.market(for: code), "ACodeResolver should accept \(code)")
        }
    }

    func test_regression_agreementOnCodesBothHandle() {
        // For codes StockSymbol *does* accept, the two should still agree on
        // sh/sz/bj (they diverge only on the 5/9/900-prefix edge cases above).
        let sharedCases: [(code: String, expected: ACodeResolver.Market)] = [
            ("600519", .sh),
            ("000001", .sz),
            ("300059", .sz),
        ]
        for (code, expectedMarket) in sharedCases {
            guard let symbol = StockSymbol(code: code) else {
                return XCTFail("StockSymbol unexpectedly rejected \(code)")
            }
            XCTAssertEqual(symbol.prefix, expectedMarket.rawValue)
            XCTAssertEqual(ACodeResolver.market(for: code), expectedMarket)
        }
    }
}
