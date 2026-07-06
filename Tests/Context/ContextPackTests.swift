import XCTest
@testable import RiseOn

/// Covers task.md S8.1's verification point: "序列化字段名与状态枚举与 Python 侧一致"
/// (serialized field names and status enum values match the Python side).
/// Rather than just trusting Swift's `Codable` round-trip (which would
/// still pass even if every key were accidentally camelCase), these tests
/// inspect the actual encoded JSON dictionary and check for the literal
/// snake_case keys `src/schemas/analysis_context_pack.py` uses.
final class ContextPackTests: XCTestCase {

    private func encodeToJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(object)
    }

    // MARK: - ContextFieldStatus raw values (must match the Python str-Enum values)

    func test_contextFieldStatus_rawValuesMatchPython() {
        XCTAssertEqual(ContextFieldStatus.available.rawValue, "available")
        XCTAssertEqual(ContextFieldStatus.missing.rawValue, "missing")
        XCTAssertEqual(ContextFieldStatus.notSupported.rawValue, "not_supported")
        XCTAssertEqual(ContextFieldStatus.fallback.rawValue, "fallback")
        XCTAssertEqual(ContextFieldStatus.stale.rawValue, "stale")
        XCTAssertEqual(ContextFieldStatus.estimated.rawValue, "estimated")
        XCTAssertEqual(ContextFieldStatus.partial.rawValue, "partial")
        XCTAssertEqual(ContextFieldStatus.fetchFailed.rawValue, "fetch_failed")
        XCTAssertEqual(ContextFieldStatus.allCases.count, 8)
    }

    // MARK: - JSON key names

    func test_contextPackSubject_serializesWithPythonKeyNames() throws {
        let subject = ContextPackSubject(code: "600519", stockName: "贵州茅台", market: "sh")
        let json = try encodeToJSONObject(subject)

        XCTAssertEqual(json["code"] as? String, "600519")
        XCTAssertEqual(json["stock_name"] as? String, "贵州茅台", "must be stock_name, not stockName")
        XCTAssertEqual(json["market"] as? String, "sh")
    }

    func test_contextItem_serializesWithPythonKeyNames() throws {
        let item = ContextItem(
            status: .fallback,
            value: .double(1.5),
            source: "tencent",
            timestamp: "2026-07-06T00:00:00Z",
            fallbackFrom: "daily_bars",
            missingReason: "network timeout",
            warnings: ["stale_cache"]
        )
        let json = try encodeToJSONObject(item)

        XCTAssertEqual(json["status"] as? String, "fallback")
        XCTAssertEqual(json["fallback_from"] as? String, "daily_bars", "must be fallback_from, not fallbackFrom")
        XCTAssertEqual(json["missing_reason"] as? String, "network timeout", "must be missing_reason, not missingReason")
        XCTAssertNotNil(json["warnings"])
        XCTAssertNotNil(json["metadata"])
    }

    func test_dataQuality_serializesWithPythonKeyNames() throws {
        let quality = DataQuality(overallScore: 80, level: "usable", blockScores: ["quote": 100], limitations: ["technical: partial"])
        let json = try encodeToJSONObject(quality)

        XCTAssertEqual(json["overall_score"] as? Int, 80, "must be overall_score, not overallScore")
        XCTAssertEqual(json["level"] as? String, "usable")
        XCTAssertEqual(json["block_scores"] as? [String: Int], ["quote": 100], "must be block_scores, not blockScores")
    }

    func test_contextPack_serializesWithPythonKeyNames() throws {
        let pack = ContextPack(
            subject: ContextPackSubject(code: "600519", stockName: "贵州茅台", market: "sh"),
            blocks: ["quote": ContextBlock(status: .available)]
        )
        let json = try encodeToJSONObject(pack)

        XCTAssertNotNil(json["subject"])
        XCTAssertEqual(json["pack_version"] as? String, "1.0", "must be pack_version, not packVersion")
        XCTAssertNotNil(json["blocks"])
        XCTAssertNotNil(json["data_quality"], "must be data_quality, not dataQuality")
        XCTAssertNotNil(json["created_at"], "must be created_at, not createdAt")
        XCTAssertNil(json["phase"], "phase is deliberately not ported (server-only concept)")
    }

    // MARK: - Codable round-trip

    func test_fullContextPack_roundTrips() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let original = ContextPack(
            subject: ContextPackSubject(code: "600519", stockName: "贵州茅台", market: "sh"),
            blocks: [
                "quote": ContextBlock(
                    status: .available,
                    items: ["price": ContextItem(status: .available, value: .double(1700.5))],
                    source: "tencent_realtime"
                ),
                "levels": ContextBlock(
                    status: .available,
                    items: ["support_levels": ContextItem(status: .available, value: .doubleArray([1650.0, 1600.0]))]
                ),
            ],
            dataQuality: DataQuality(overallScore: 80, level: "usable", blockScores: ["quote": 100]),
            createdAt: Date(timeIntervalSince1970: 1_750_000_000)
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ContextPack.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - JSONValue

    func test_jsonValue_roundTripsEveryCase() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let values: [JSONValue] = [
            .string("hello"),
            .int(42),
            .double(3.14),
            .bool(true),
            .null,
            .array([.int(1), .string("two"), .bool(false)]),
            .object(["a": .int(1), "b": .string("x")]),
        ]

        for value in values {
            let data = try encoder.encode(value)
            let decoded = try decoder.decode(JSONValue.self, from: data)
            XCTAssertEqual(decoded, value)
        }
    }

    func test_jsonValue_literalsConstructNaturally() {
        let string: JSONValue = "hello"
        let number: JSONValue = 42
        let flag: JSONValue = true
        let list: JSONValue = [1, "two", true]
        let none: JSONValue = nil

        XCTAssertEqual(string, .string("hello"))
        XCTAssertEqual(number, .int(42))
        XCTAssertEqual(flag, .bool(true))
        XCTAssertEqual(list, .array([.int(1), .string("two"), .bool(true)]))
        XCTAssertEqual(none, .null)
    }

    func test_jsonValue_doubleArrayConvenience() {
        let value = JSONValue.doubleArray([1.5, 2.5, 3.5])
        XCTAssertEqual(value, .array([.double(1.5), .double(2.5), .double(3.5)]))
    }
}
