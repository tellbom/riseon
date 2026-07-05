import Foundation

/// Independent A-share code normalizer (task.md S2.3, plan.md §0.5-3).
///
/// This deliberately does **not** reuse `Shared/Models/StockSymbol.swift`.
/// That existing type only accepts codes starting with `0/3/4/6/8` (used by
/// the watchlist/Watch UI) and must not be touched per S1.1. `ACodeResolver`
/// mirrors the more precise Python rule instead:
///
/// - `data_provider/base.py::is_bse_code`: BSE (Beijing) codes start with
///   `92/43/81/82/83/87/88`, **except** `900xxx` which is a Shanghai B-share,
///   not BSE.
/// - `data_provider/tencent_fetcher.py::_to_tencent_symbol`: BSE -> `bj`;
///   otherwise codes starting with `6/5/9` -> `sh`; everything else -> `sz`.
///
/// Order matters: the BSE check must run before the `6/5/9` check, since a
/// BSE code can itself start with `9` (e.g. `920xxx`) and must not be
/// misclassified as Shanghai.
public enum ACodeResolver {
    public enum Market: String, Codable, Equatable, Hashable, Sendable {
        case sh
        case sz
        case bj
    }

    /// Mirrors `data_provider/base.py::is_bse_code`.
    public static func isBSECode(_ code: String) -> Bool {
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return false
        }
        if code.hasPrefix("900") {
            return false
        }
        let bsePrefixes = ["92", "43", "81", "82", "83", "87", "88"]
        return bsePrefixes.contains { code.hasPrefix($0) }
    }

    /// Resolves the market for a normalized 6-digit A-share code. Returns
    /// `nil` for anything that isn't a plain 6-digit numeric code (this
    /// resolver does not handle HK/US/exchange-suffixed forms).
    public static func market(for code: String) -> Market? {
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        if isBSECode(code) {
            return .bj
        }
        if code.hasPrefix("6") || code.hasPrefix("5") || code.hasPrefix("9") {
            return .sh
        }
        return .sz
    }

    /// Full `{prefix}{code}` symbol, e.g. `600519 -> sh600519`. Returns `nil`
    /// under the same conditions as `market(for:)`.
    public static func fullSymbol(for code: String) -> String? {
        guard let market = market(for: code) else {
            return nil
        }
        return market.rawValue + code
    }
}
