import Foundation

// MARK: - Provider protocols (collector-level seams for mocking)

/// Each source is fetched behind its own tiny protocol so the aggregating
/// `ExternalFactorCollector` can be unit-tested with mocks that succeed or
/// throw at will (verifying per-source degradation), exactly how
/// `DailyBarsProvider` lets `WorkspaceInitializationCoordinator` be tested
/// without a network. The concrete actors below each also expose a pure
/// `parse(...)` for fixture-based decode tests (same convention as
/// `TencentDailyProvider.parseBars`).

public protocol CapitalFlowProviding: Sendable {
    /// Ascending by date; last element is the most recent trading day.
    func fetch(secid: String) async throws -> [CapitalFlowSnapshot]
}

public protocol ValuationProviding: Sendable {
    func fetch(fullSymbol: String) async throws -> ValuationSnapshot
}

public protocol DragonTigerProviding: Sendable {
    func fetch(code: String) async throws -> [DragonTigerRecord]
}

public protocol LimitUpProviding: Sendable {
    /// Returns a status even when the stock isn't limit-up (that's a real
    /// answer: `isLimitUp == false`); only throws on a network/parse failure.
    func fetch(code: String, dateYYYYMMDD: String) async throws -> LimitUpStatus
}

public protocol SectorProviding: Sendable {
    func fetch(secid: String) async throws -> SectorHeat
}

public protocol FundamentalForecastProviding: Sendable {
    /// Latest 业绩预告 (type, summary); `nil` when the stock has none.
    func fetch(code: String) async throws -> (type: String?, summary: String?)?
}

public protocol AnnouncementProviding: Sendable {
    func fetch(code: String) async throws -> [AnnouncementItem]
}

// MARK: - 主力资金流（东财 push2his）

public actor EastmoneyCapitalFlowProvider: CapitalFlowProviding {
    public init() {}

    public func fetch(secid: String) async throws -> [CapitalFlowSnapshot] {
        let url = "https://push2his.eastmoney.com/api/qt/stock/fflow/daykline/get"
            + "?lmt=64&klt=101&fields1=f1,f2,f3,f7"
            + "&fields2=f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61,f62,f63"
            + "&secid=\(secid)&ut=b2884a393a59ad64002292a3e90d46a5"
        let data = try await ExternalDataHTTP.get(url)
        return Self.parse(data)
    }

    /// Response: `data.klines[]`, each a comma-joined row:
    /// `日期,主力净额,小单净额,中单净额,大单净额,超大单净额,主力净占比,
    ///  小单占比,中单占比,大单占比,超大单占比,收盘价,涨跌幅`.
    public nonisolated static func parse(_ data: Data) -> [CapitalFlowSnapshot] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = root["data"] as? [String: Any],
              let klines = block["klines"] as? [String] else {
            return []
        }
        return klines.compactMap { line -> CapitalFlowSnapshot? in
            let f = line.components(separatedBy: ",")
            guard f.count >= 13, let main = ExternalDataParsing.number(f[1]) else { return nil }
            return CapitalFlowSnapshot(
                date: f[0],
                mainNetInflow: main,
                mainNetInflowRatio: ExternalDataParsing.number(f[6]),
                superLargeNet: ExternalDataParsing.number(f[5]),
                largeNet: ExternalDataParsing.number(f[4]),
                mediumNet: ExternalDataParsing.number(f[3]),
                smallNet: ExternalDataParsing.number(f[2]),
                close: ExternalDataParsing.number(f[11]),
                changePct: ExternalDataParsing.number(f[12])
            )
        }
    }
}

// MARK: - 换手率/量比/PE/PB/市值（腾讯行情行，复用已连的 host）

public actor TencentValuationProvider: ValuationProviding {
    public init() {}

    public func fetch(fullSymbol: String) async throws -> ValuationSnapshot {
        let data = try await ExternalDataHTTP.get("https://qt.gtimg.cn/q=\(fullSymbol)")
        let encoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringConvertIANACharSetNameToEncoding("GB18030" as CFString)
        )
        guard let text = String(data: data, encoding: String.Encoding(rawValue: encoding)),
              let snapshot = Self.parse(text: text, fullSymbol: fullSymbol) else {
            throw ExternalDataHTTP.HTTPError.emptyResponse
        }
        return snapshot
    }

    /// Same `~`-delimited Tencent row `TencentQuoteProvider` parses, but for
    /// the extended valuation indices it doesn't read (this app doesn't touch
    /// the shared `TencentQuoteProvider`, so it re-fetches independently).
    /// Indices per the feasibility review; volume-ratio/PB positions are the
    /// least certain, so all fields are optional and parsed defensively.
    public nonisolated static func parse(text: String, fullSymbol: String) -> ValuationSnapshot? {
        let marker = "v_\(fullSymbol)=\""
        guard let markerRange = text.range(of: marker),
              let end = text.range(of: "\"", range: markerRange.upperBound..<text.endIndex) else {
            return nil
        }
        let fields = String(text[markerRange.upperBound..<end.lowerBound]).components(separatedBy: "~")
        func f(_ index: Int) -> Double? {
            guard index < fields.count else { return nil }
            return ExternalDataParsing.number(fields[index])
        }
        let snapshot = ValuationSnapshot(
            turnoverRate: f(38),
            volumeRatio: f(49),
            peTTM: f(39),
            pb: f(46),
            totalMarketCap: f(45),
            floatMarketCap: f(44)
        )
        return snapshot.hasAnyValue ? snapshot : nil
    }
}

// MARK: - 龙虎榜（东财 datacenter-web）

public actor EastmoneyDragonTigerProvider: DragonTigerProviding {
    public init() {}

    public func fetch(code: String) async throws -> [DragonTigerRecord] {
        let url = "https://datacenter-web.eastmoney.com/api/data/v1/get"
            + "?reportName=RPT_DAILYBILLBOARD_DETAILSNEW&columns=ALL"
            + "&filter=(SECURITY_CODE=%22\(code)%22)"
            + "&pageNumber=1&pageSize=20&sortColumns=TRADE_DATE&sortTypes=-1&source=WEB&client=WEB"
        let data = try await ExternalDataHTTP.get(url)
        return Self.parse(data)
    }

    public nonisolated static func parse(_ data: Data) -> [DragonTigerRecord] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let rows = result["data"] as? [[String: Any]] else {
            return []
        }
        return rows.compactMap { row -> DragonTigerRecord? in
            guard let rawDate = ExternalDataParsing.string(row["TRADE_DATE"]) else { return nil }
            return DragonTigerRecord(
                date: String(rawDate.prefix(10)),
                explanation: ExternalDataParsing.string(row["EXPLANATION"]),
                netBuy: ExternalDataParsing.number(row["BILLBOARD_NET_AMT"]),
                buyAmount: ExternalDataParsing.number(row["BILLBOARD_BUY_AMT"]),
                sellAmount: ExternalDataParsing.number(row["BILLBOARD_SELL_AMT"]),
                turnoverRate: ExternalDataParsing.number(row["TURNOVERRATE"])
            )
        }
    }
}

// MARK: - 涨跌停池（东财 push2ex）

public actor EastmoneyLimitUpProvider: LimitUpProviding {
    public init() {}

    public func fetch(code: String, dateYYYYMMDD: String) async throws -> LimitUpStatus {
        let ztURL = poolURL(topic: "getTopicZTPool", date: dateYYYYMMDD)
        let ztData = try await ExternalDataHTTP.get(ztURL)
        if let up = Self.parse(ztData, code: code, date: dateYYYYMMDD, isUp: true) {
            return up
        }
        // Not in the 涨停 pool — check 跌停 pool before concluding "neither".
        let dtURL = poolURL(topic: "getTopicDTPool", date: dateYYYYMMDD)
        if let dtData = try? await ExternalDataHTTP.get(dtURL),
           let down = Self.parse(dtData, code: code, date: dateYYYYMMDD, isUp: false) {
            return down
        }
        return LimitUpStatus(date: dateYYYYMMDD, isLimitUp: false, isLimitDown: false)
    }

    private nonisolated func poolURL(topic: String, date: String) -> String {
        "https://push2ex.eastmoney.com/\(topic)"
            + "?ut=7eea3edcaed734bea9cbfc24409ed989&dpt=wz.ztzt"
            + "&Pageindex=0&pagesize=800&sort=fbt%3Aasc&date=\(date)"
    }

    /// Response: `data.pool[]` of `{c,n,zdp,hs,lbc,fbt,zbc,fund,hybk,zttj{days,ct}}`.
    /// Returns `nil` when `code` isn't present in this pool.
    public nonisolated static func parse(_ data: Data, code: String, date: String, isUp: Bool) -> LimitUpStatus? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = root["data"] as? [String: Any],
              let pool = block["pool"] as? [[String: Any]] else {
            return nil
        }
        guard let entry = pool.first(where: { ExternalDataParsing.string($0["c"]) == code }) else {
            return nil
        }
        let fbt = ExternalDataParsing.number(entry["fbt"]).map { String(Int($0)) }
        return LimitUpStatus(
            date: date,
            isLimitUp: isUp,
            isLimitDown: !isUp,
            boardCount: ExternalDataParsing.number(entry["lbc"]).map { Int($0) },
            openTimes: ExternalDataParsing.number(entry["zbc"]).map { Int($0) },
            firstSealTime: fbt,
            sealAmount: ExternalDataParsing.number(entry["fund"]),
            industry: ExternalDataParsing.string(entry["hybk"])
        )
    }
}

// MARK: - 行业板块归属与热度（东财 push2）

public actor EastmoneySectorProvider: SectorProviding {
    public init() {}

    public func fetch(secid: String) async throws -> SectorHeat {
        // 1. The stock's industry name (f127).
        let stockURL = "https://push2.eastmoney.com/api/qt/stock/get?secid=\(secid)&fields=f127,f128"
        let stockData = try await ExternalDataHTTP.get(stockURL)
        let industryName = Self.parseIndustryName(stockData)

        // 2. Match that industry against the ranked industry-board flow list
        //    to get its main-flow / rank / change (板块热度). Best-effort — if
        //    the match fails we still return the归属 name.
        guard let industryName else { return SectorHeat() }
        let listURL = "https://push2.eastmoney.com/api/qt/clist/get"
            + "?fs=m:90+t:2&fields=f12,f14,f62,f184,f3&pn=1&pz=200&po=1&fid=f62"
        guard let listData = try? await ExternalDataHTTP.get(listURL) else {
            return SectorHeat(industryName: industryName)
        }
        return Self.parseBoardHeat(listData, industryName: industryName)
    }

    public nonisolated static func parseIndustryName(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = root["data"] as? [String: Any] else {
            return nil
        }
        return ExternalDataParsing.string(block["f127"])
    }

    /// `data.diff` is a list of industry boards ranked by main net inflow.
    /// Modern Eastmoney returns it as an array; older responses use a
    /// dict keyed by index — tolerate both.
    public nonisolated static func parseBoardHeat(_ data: Data, industryName: String) -> SectorHeat {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = root["data"] as? [String: Any] else {
            return SectorHeat(industryName: industryName)
        }
        let boards: [[String: Any]]
        if let array = block["diff"] as? [[String: Any]] {
            boards = array
        } else if let dict = block["diff"] as? [String: Any] {
            boards = dict.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.compactMap { dict[$0] as? [String: Any] }
        } else {
            boards = []
        }
        guard let match = boards.first(where: { ExternalDataParsing.string($0["f14"]) == industryName }) else {
            return SectorHeat(industryName: industryName)
        }
        return SectorHeat(
            industryName: industryName,
            mainNetInflow: ExternalDataParsing.number(match["f62"]),
            mainNetInflowRatio: ExternalDataParsing.number(match["f184"]),
            changePct: ExternalDataParsing.number(match["f3"])
        )
    }
}

// MARK: - 业绩预告（东财 datacenter-web）

public actor EastmoneyFundamentalForecastProvider: FundamentalForecastProviding {
    public init() {}

    public func fetch(code: String) async throws -> (type: String?, summary: String?)? {
        let url = "https://datacenter-web.eastmoney.com/api/data/v1/get"
            + "?reportName=RPT_PUBLIC_OP_PREDICT&columns=ALL"
            + "&filter=(SECURITY_CODE=%22\(code)%22)"
            + "&pageNumber=1&pageSize=1&sortColumns=NOTICE_DATE&sortTypes=-1&source=WEB&client=WEB"
        let data = try await ExternalDataHTTP.get(url)
        return Self.parse(data)
    }

    public nonisolated static func parse(_ data: Data) -> (type: String?, summary: String?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let rows = result["data"] as? [[String: Any]],
              let first = rows.first else {
            return nil
        }
        let type = ExternalDataParsing.string(first["PREDICT_TYPE"])
        let summary = ExternalDataParsing.string(first["PREDICT_CONTENT"])
            ?? ExternalDataParsing.string(first["PREDICT_FINANCE"])
        if type == nil && summary == nil { return nil }
        return (type, summary)
    }
}

// MARK: - 公告（东财 np-anotice，单次 GET，无需 orgId）

public actor EastmoneyAnnouncementProvider: AnnouncementProviding {
    public init() {}

    public func fetch(code: String) async throws -> [AnnouncementItem] {
        let url = "https://np-anotice-stock.eastmoney.com/api/security/ann"
            + "?sr=-1&page_size=15&page_index=1&ann_type=A&client_source=web&stock_list=\(code)"
        let data = try await ExternalDataHTTP.get(url)
        return Self.parse(data)
    }

    public nonisolated static func parse(_ data: Data) -> [AnnouncementItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = root["data"] as? [String: Any],
              let list = block["list"] as? [[String: Any]] else {
            return []
        }
        return list.compactMap { row -> AnnouncementItem? in
            guard let title = ExternalDataParsing.string(row["title"]),
                  let date = ExternalDataParsing.string(row["notice_date"]) else {
                return nil
            }
            let type = (row["columns"] as? [[String: Any]])?.first
                .flatMap { ExternalDataParsing.string($0["column_name"]) }
            let artCode = ExternalDataParsing.string(row["art_code"])
            let url = artCode.map { "https://data.eastmoney.com/notices/detail/\($0).html" }
            return AnnouncementItem(title: title, date: String(date.prefix(10)), type: type, url: url)
        }
    }
}
