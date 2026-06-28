import Foundation

struct StockSearchResult: Identifiable, Hashable {
    var id: String { fullSymbol }

    let code: String
    let name: String
    let market: String
    let fullSymbol: String
}

actor StockSearchService {
    func search(keyword: String) async -> [StockSearchResult] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://smartbox.gtimg.cn/s3/?v=2&q=\(encoded)&t=all&_=\(Int(Date().timeIntervalSince1970 * 1000))") else {
            return []
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 6

        guard let (data, _) = try? await URLSession.shared.data(for: request) else {
            return []
        }

        return parse(data: data)
    }

    nonisolated func parse(data: Data) -> [StockSearchResult] {
        let encoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringConvertIANACharSetNameToEncoding("GB18030" as CFString)
        )
        guard let text = String(data: data, encoding: String.Encoding(rawValue: encoding)),
              let start = text.range(of: "\""),
              let end = text.range(of: "\"", range: start.upperBound..<text.endIndex) else {
            return []
        }

        let payload = String(text[start.upperBound..<end.lowerBound])
        let lines = payload
            .components(separatedBy: "^")
            .flatMap { $0.components(separatedBy: "\\n") }

        var results: [StockSearchResult] = []
        var seen = Set<String>()

        for line in lines {
            if let result = parseTildeSeparatedLine(line, seen: &seen) ?? parseCaretSeparatedLine(line, seen: &seen) {
                results.append(result)
            }

            if results.count >= 8 {
                break
            }
        }

        return results
    }

    private nonisolated func parseTildeSeparatedLine(_ line: String, seen: inout Set<String>) -> StockSearchResult? {
        let parts = line.components(separatedBy: "~")
        guard parts.count >= 5 else {
            return nil
        }

        let market = parts[0]
        let code = parts[1]
        let name = decodedEscapedUnicode(parts[2])
        let category = parts[4]

        guard category == "GP-A",
              ["sh", "sz", "bj"].contains(market),
              StockSymbol(code: code) != nil,
              seen.insert(code).inserted else {
            return nil
        }

        return StockSearchResult(code: code, name: name, market: market, fullSymbol: market + code)
    }

    private nonisolated func parseCaretSeparatedLine(_ line: String, seen: inout Set<String>) -> StockSearchResult? {
        let parts = line.components(separatedBy: "^")
        guard parts.count >= 5 else {
            return nil
        }

        let type = parts[0]
        let fullSymbol = parts[1]
        let code = parts[2]
        let name = decodedEscapedUnicode(parts[3])

        guard type == "11",
              !code.isEmpty,
              !name.isEmpty,
              StockSymbol(code: code) != nil,
              seen.insert(code).inserted else {
            return nil
        }

        let market: String
        if fullSymbol.hasPrefix("sh") {
            market = "sh"
        } else if fullSymbol.hasPrefix("sz") {
            market = "sz"
        } else if fullSymbol.hasPrefix("bj") {
            market = "bj"
        } else {
            return nil
        }

        return StockSearchResult(code: code, name: name, market: market, fullSymbol: fullSymbol)
    }

    private nonisolated func decodedEscapedUnicode(_ value: String) -> String {
        guard value.contains("\\u"),
              let data = "\"\(value)\"".data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else {
            return value
        }

        return decoded
    }
}
