import Combine
import Foundation

/// Persists the ordered watchlist of stock codes in UserDefaults.
@MainActor
public final class WatchlistStore: ObservableObject {
    @Published public private(set) var codes: [String]

    private let defaults: UserDefaults
    private let key: String

    public init(suiteName: String? = nil, key: String = "watchlist_codes") {
        self.defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.key = key
        self.codes = Self.normalized(defaults.array(forKey: key) as? [String] ?? [])
    }

    /// Appends a code if it is non-empty and not already present.
    public func add(_ code: String) {
        let normalizedCode = Self.normalizedCode(code)
        guard let normalizedCode, !codes.contains(normalizedCode) else {
            return
        }

        codes.append(normalizedCode)
        save()
    }

    /// Removes codes at the given offsets, matching SwiftUI List onDelete semantics.
    public func remove(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where codes.indices.contains(index) {
            codes.remove(at: index)
        }
        save()
    }

    /// Removes a code if present.
    public func remove(_ code: String) {
        guard let normalizedCode = Self.normalizedCode(code) else {
            return
        }

        codes.removeAll { $0 == normalizedCode }
        save()
    }

    /// Replaces the whole watchlist, preserving first-seen order and removing duplicates.
    public func replace(with newCodes: [String]) {
        codes = Self.normalized(newCodes)
        save()
    }

    private func save() {
        defaults.set(codes, forKey: key)
    }

    private static func normalized(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for code in codes {
            guard let normalizedCode = normalizedCode(code),
                  seen.insert(normalizedCode).inserted else {
                continue
            }

            result.append(normalizedCode)
        }

        return result
    }

    private static func normalizedCode(_ code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
