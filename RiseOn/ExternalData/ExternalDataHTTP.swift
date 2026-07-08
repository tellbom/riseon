import Foundation

/// Small shared HTTP helper for the on-device external-factor providers.
/// Network I/O lives here and in the providers only — same "纪律" as the
/// existing `QuoteProvider`/`DailyBarsProvider` layer (plan.md §13): the
/// `Analytics`/`Context` layers stay pure.
///
/// Every call is low-frequency (fired once when the user opens/refreshes a
/// single stock), so a single one-shot retry after a short delay is enough —
/// mirroring `TencentDailyProvider`'s S5.3 `fetchWithRetry`. The feasibility
/// review flagged that Eastmoney rate-limits *high-frequency batch* scraping
/// (the reason `remote_fund_flow_proxy` exists); this single-stock, on-demand
/// pattern is well under that threshold.
enum ExternalDataHTTP {
    enum HTTPError: Error {
        case badURL
        case emptyResponse
    }

    /// Default browser-ish headers — several Eastmoney/CNInfo endpoints 反爬
    /// on missing UA/Referer.
    static let defaultHeaders: [String: String] = [
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
        "Accept": "*/*",
    ]

    /// GET raw bytes, one retry after 1s on failure.
    static func get(
        _ urlString: String,
        headers: [String: String] = defaultHeaders,
        timeout: TimeInterval = 8
    ) async throws -> Data {
        do {
            return try await getOnce(urlString, headers: headers, timeout: timeout)
        } catch {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return try await getOnce(urlString, headers: headers, timeout: timeout)
        }
    }

    private static func getOnce(
        _ urlString: String,
        headers: [String: String],
        timeout: TimeInterval
    ) async throws -> Data {
        guard let url = URL(string: urlString) else { throw HTTPError.badURL }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = timeout
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, _) = try await URLSession.shared.data(for: request)
        guard !data.isEmpty else { throw HTTPError.emptyResponse }
        return data
    }
}

/// Shared numeric coercion — Eastmoney/CNInfo return numbers as either JSON
/// numbers or numeric strings, and use `"-"` / `""` for null. Mirrors
/// `TencentDailyProvider.number(_:)`'s tolerance.
enum ExternalDataParsing {
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "-" { return nil }
            return Double(trimmed)
        default: return nil
        }
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        case let d as Double: return String(d)
        case let i as Int: return String(i)
        default: return nil
        }
    }
}
