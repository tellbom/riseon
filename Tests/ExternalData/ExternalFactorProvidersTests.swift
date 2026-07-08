import XCTest
@testable import RiseOn

/// Fixture-based decode tests for the on-device external-factor providers —
/// same convention as `TencentDailyProviderTests` (parse the raw response
/// shape without touching the network). Verifies field mapping and defensive
/// tolerance of missing/`"-"` values.
final class ExternalFactorProvidersTests: XCTestCase {

    private func data(_ string: String) -> Data { Data(string.utf8) }

    // MARK: - 主力资金流

    func test_capitalFlow_parsesKlinesRowOrder() {
        let json = """
        {"data":{"klines":[
          "2024-06-03,1234567.0,-100,200,300,400,5.5,1.1,2.2,3.3,4.4,10.5,1.2",
          "2024-06-04,-50000,-10,20,30,40,-0.5,0,0,0,0,10.4,-0.9"
        ]}}
        """
        let result = EastmoneyCapitalFlowProvider.parse(data(json))
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].date, "2024-06-03")
        XCTAssertEqual(result[0].mainNetInflow, 1234567.0)
        XCTAssertEqual(result[0].smallNet, -100)
        XCTAssertEqual(result[0].superLargeNet, 400)
        XCTAssertEqual(result[0].mainNetInflowRatio, 5.5)
        XCTAssertEqual(result[0].close, 10.5)
        XCTAssertEqual(result[0].changePct, 1.2)
        XCTAssertEqual(result[1].mainNetInflow, -50000)
    }

    func test_capitalFlow_emptyOrMalformed_returnsEmpty() {
        XCTAssertTrue(EastmoneyCapitalFlowProvider.parse(data("{}")).isEmpty)
        XCTAssertTrue(EastmoneyCapitalFlowProvider.parse(data("not json")).isEmpty)
        // Row too short -> skipped, not a crash.
        XCTAssertTrue(EastmoneyCapitalFlowProvider.parse(data("{\"data\":{\"klines\":[\"2024-06-03,1\"]}}")).isEmpty)
    }

    // MARK: - 估值（腾讯行情行）

    func test_valuation_parsesExtendedIndices() {
        var fields = Array(repeating: "0", count: 60)
        fields[1] = "贵州茅台"
        fields[38] = "3.2"    // 换手率
        fields[39] = "25.5"   // PE TTM
        fields[44] = "1500.0" // 流通市值
        fields[45] = "2000.0" // 总市值
        fields[46] = "8.5"    // PB
        fields[49] = "1.3"    // 量比
        let text = "v_sh600519=\"" + fields.joined(separator: "~") + "\";"

        let snapshot = TencentValuationProvider.parse(text: text, fullSymbol: "sh600519")
        XCTAssertEqual(snapshot?.turnoverRate, 3.2)
        XCTAssertEqual(snapshot?.peTTM, 25.5)
        XCTAssertEqual(snapshot?.pb, 8.5)
        XCTAssertEqual(snapshot?.volumeRatio, 1.3)
        XCTAssertEqual(snapshot?.floatMarketCap, 1500.0)
        XCTAssertEqual(snapshot?.totalMarketCap, 2000.0)
    }

    func test_valuation_wrongSymbolMarker_returnsNil() {
        let text = "v_sh600519=\"1~名~600519~10\";"
        XCTAssertNil(TencentValuationProvider.parse(text: text, fullSymbol: "sz000001"))
    }

    // MARK: - 龙虎榜

    func test_dragonTiger_parsesRowsAndTrimsDate() {
        let json = """
        {"result":{"data":[
          {"TRADE_DATE":"2024-06-03 00:00:00","EXPLANATION":"日涨幅偏离值达7%",
           "BILLBOARD_NET_AMT":5000000,"BILLBOARD_BUY_AMT":8000000,
           "BILLBOARD_SELL_AMT":3000000,"TURNOVERRATE":12.5}
        ]}}
        """
        let records = EastmoneyDragonTigerProvider.parse(data(json))
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].date, "2024-06-03")
        XCTAssertEqual(records[0].explanation, "日涨幅偏离值达7%")
        XCTAssertEqual(records[0].netBuy, 5000000)
        XCTAssertEqual(records[0].turnoverRate, 12.5)
    }

    // MARK: - 涨跌停池

    func test_limitUp_findsCodeInPool() {
        let json = """
        {"data":{"pool":[
          {"c":"600519","n":"贵州茅台","lbc":2,"zbc":0,"fbt":93005,"fund":100000000,"hybk":"白酒"},
          {"c":"000001","n":"平安银行","lbc":1}
        ]}}
        """
        let status = EastmoneyLimitUpProvider.parse(data(json), code: "600519", date: "20240603", isUp: true)
        XCTAssertEqual(status?.isLimitUp, true)
        XCTAssertEqual(status?.boardCount, 2)
        XCTAssertEqual(status?.industry, "白酒")
        XCTAssertEqual(status?.firstSealTime, "93005")
    }

    func test_limitUp_codeAbsent_returnsNil() {
        let json = "{\"data\":{\"pool\":[{\"c\":\"000001\"}]}}"
        XCTAssertNil(EastmoneyLimitUpProvider.parse(data(json), code: "600519", date: "20240603", isUp: true))
    }

    // MARK: - 行业板块

    func test_sector_parsesIndustryNameAndBoardHeat() {
        XCTAssertEqual(EastmoneySectorProvider.parseIndustryName(data("{\"data\":{\"f127\":\"白酒\"}}")), "白酒")

        let listJSON = """
        {"data":{"diff":[
          {"f12":"BK0475","f14":"白酒","f62":123456,"f184":3.2,"f3":1.5},
          {"f12":"BK0999","f14":"银行","f62":50000,"f184":1.0,"f3":0.3}
        ]}}
        """
        let heat = EastmoneySectorProvider.parseBoardHeat(data(listJSON), industryName: "白酒")
        XCTAssertEqual(heat.industryName, "白酒")
        XCTAssertEqual(heat.mainNetInflow, 123456)
        XCTAssertEqual(heat.changePct, 1.5)
    }

    func test_sector_boardHeat_noMatch_keepsNameOnly() {
        let listJSON = "{\"data\":{\"diff\":[{\"f14\":\"银行\",\"f62\":1}]}}"
        let heat = EastmoneySectorProvider.parseBoardHeat(data(listJSON), industryName: "白酒")
        XCTAssertEqual(heat.industryName, "白酒")
        XCTAssertNil(heat.mainNetInflow)
    }

    // MARK: - 业绩预告

    func test_fundamentalForecast_parsesLatest() {
        let json = """
        {"result":{"data":[
          {"PREDICT_TYPE":"预增","PREDICT_CONTENT":"净利润同比增长50%","NOTICE_DATE":"2024-07-01"}
        ]}}
        """
        let forecast = EastmoneyFundamentalForecastProvider.parse(data(json))
        XCTAssertEqual(forecast?.type, "预增")
        XCTAssertEqual(forecast?.summary, "净利润同比增长50%")
    }

    func test_fundamentalForecast_empty_returnsNil() {
        XCTAssertNil(EastmoneyFundamentalForecastProvider.parse(data("{\"result\":{\"data\":[]}}")))
    }

    // MARK: - 公告

    func test_announcements_parsesListAndBuildsURL() {
        let json = """
        {"data":{"list":[
          {"title":"关于回购股份的公告","notice_date":"2024-07-01 16:00:00",
           "art_code":"AN2024","columns":[{"column_name":"回购"}]}
        ]}}
        """
        let items = EastmoneyAnnouncementProvider.parse(data(json))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "关于回购股份的公告")
        XCTAssertEqual(items[0].date, "2024-07-01")
        XCTAssertEqual(items[0].type, "回购")
        XCTAssertEqual(items[0].url, "https://data.eastmoney.com/notices/detail/AN2024.html")
    }
}
