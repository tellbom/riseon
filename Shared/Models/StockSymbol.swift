import Foundation

/// A validated A-share stock code with its resolved market prefix.
public struct StockSymbol: Hashable, Codable, Sendable {
    public let code: String
    public let prefix: String

    public nonisolated var fullSymbol: String {
        prefix + code
    }

    public nonisolated init?(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let first = trimmed.first else {
            return nil
        }

        switch first {
        case "6":
            prefix = "sh"
        case "0", "3":
            prefix = "sz"
        case "4", "8":
            prefix = "bj"
        default:
            return nil
        }

        self.code = trimmed
    }
}
