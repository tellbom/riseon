import XCTest
@testable import RiseOn

/// Covers the parsing half of task.md S5.1's verification point (field order,
/// volume unit conversion) via fixtures — `parseBars` is exposed
/// `nonisolated` specifically for this, same reasoning as
/// `TencentQuoteProvider.parse`/`TencentMinuteProvider.parsePoints`.
///
/// NOTE: the live-network half of S5.1's verification ("600519 拉到近 120+
/// 根日线") needs an actual device/simulator hitting `web.ifzq.gtimg.cn` —
/// this sandbox has no network access to that domain, so it isn't covered
/// here and needs a manual check once this lands in Xcode.
final class TencentDailyProviderTests: XCTestCase {

    private let provider = TencentDailyProvider()

    // MARK: - Fixtures

    /// Mirrors the real response shape from
    /// `data_provider/tencent_fetcher.py::_extract_kline_rows`: rows are
    /// `[date, open, close, high, low, volume(lots), amount]`, note close
    /// before high/low.
    private func fixtureJSON(rows: String) -> Data {
        """
        {"code":0,"msg":"","data":{"sh600519":{"qfqday":[\(rows)]}}}
        """.data(using: .utf8)!
    }

    func test_parsesFieldsInCorrectOrder_closeBeforeHighLow() {
        // open=1680.00, close=1690.50, high=1695.00, low=1675.20 — all
        // distinct values so a field-order bug (e.g. swapping close/high)
        // is caught by exact-value assertions rather than accidentally
        // passing.
        let json = fixtureJSON(rows: #"["2024-06-03","1680.00","1690.50","1695.00","1675.20","12345","2085000000"]"#)

        let bars = provider.parseBars(json: json, fullSymbol: "sh600519")

        XCTAssertEqual(bars.count, 1)
        let bar = bars[0]
        XCTAssertEqual(bar.date, "2024-06-03")
        XCTAssertEqual(bar.open, 1680.00, accuracy: 1e-9)
        XCTAssertEqual(bar.close, 1690.50, accuracy: 1e-9)
        XCTAssertEqual(bar.high, 1695.00, accuracy: 1e-9)
        XCTAssertEqual(bar.low, 1675.20, accuracy: 1e-9)
    }

    func test_volumeConvertedFromLotsToShares_times100() {
        let json = fixtureJSON(rows: #"["2024-06-03","10","11","12","9","500","0"]"#)
        let bars = provider.parseBars(json: json, fullSymbol: "sh600519")

        XCTAssertEqual(bars.first?.volume, 50_000, "500 lots * 100 = 50,000 shares")
    }

    func test_amountIsOptional_missingRow6DoesNotFailParsing() {
        // Only 6 fields (no amount) — must still parse, with amount == nil.
        let json = fixtureJSON(rows: #"["2024-06-03","10","11","12","9","500"]"#)
        let bars = provider.parseBars(json: json, fullSymbol: "sh600519")

        XCTAssertEqual(bars.count, 1)
        XCTAssertNil(bars.first?.amount)
    }

    func test_amountPresent_isParsed() {
        let json = fixtureJSON(rows: #"["2024-06-03","10","11","12","9","500","123456.0"]"#)
        let bars = provider.parseBars(json: json, fullSymbol: "sh600519")

        XCTAssertEqual(bars.first?.amount, 123456.0, accuracy: 1e-9)
    }

    func test_multipleRows_parsedInOrder() {
        let json = fixtureJSON(rows: """
        ["2024-06-03","10","11","12","9","500","0"],
        ["2024-06-04","11","12","13","10","600","0"],
        ["2024-06-05","12","13","14","11","700","0"]
        """)
        let bars = provider.parseBars(json: json, fullSymbol: "sh600519")

        XCTAssertEqual(bars.map(\.date), ["2024-06-03", "2024-06-04", "2024-06-05"])
    }

    func test_fallsBackTo_dayKey_whenQfqdayMissing() {
        let json = """
        {"data":{"sh600519":{"day":[["2024-06-03","10","11","12","9","500","0"]]}}}
        """.data(using: .utf8)!

        let bars = provider.parseBars(json: json, fullSymbol: "sh600519")
        XCTAssertEqual(bars.count, 1)
    }

    // MARK: - Defensive parsing

    func test_rowTooShort_isSkippedNotCrashing() {
        let json = fixtureJSON(rows: #"["2024-06-03","10","11"]"#) // only 3 fields
        let bars = provider.parseBars(json: json, fullSymbol: "sh600519")
        XCTAssertEqual(bars, [])
    }

    func test_wrongSymbolKey_returnsEmpty() {
        let json = fixtureJSON(rows: #"["2024-06-03","10","11","12","9","500","0"]"#)
        let bars = provider.parseBars(json: json, fullSymbol: "sz000001") // not the symbol in the fixture
        XCTAssertEqual(bars, [])
    }

    func test_malformedJSON_returnsEmptyRatherThanThrowing() {
        let json = "not json at all".data(using: .utf8)!
        let bars = provider.parseBars(json: json, fullSymbol: "sh600519")
        XCTAssertEqual(bars, [])
    }

    func test_numbersAsJSONNumbers_notJustStrings_stillParse() {
        // Tencent's kline endpoints are known to be inconsistent about
        // returning numbers vs numeric strings (plan.md §8/§16) — the parser
        // must tolerate both.
        let json = """
        {"data":{"sh600519":{"qfqday":[["2024-06-03",10,11,12,9,500,0]]}}}
        """.data(using: .utf8)!

        let bars = provider.parseBars(json: json, fullSymbol: "sh600519")
        XCTAssertEqual(bars.count, 1)
        XCTAssertEqual(bars.first?.close, 11, accuracy: 1e-9)
    }
}
