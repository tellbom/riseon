import Combine
import Foundation

/// Persists the ordered watchlist of stock codes in UserDefaults.
@MainActor
public final class WatchlistStore: ObservableObject {
    @Published public private(set) var items: [WatchlistItem]

    public var codes: [String] {
        items.map(\.code)
    }

    private let defaults: UserDefaults
    private let key: String
    private let legacyCodesKey = "watchlist_codes"

    public init(suiteName: String? = nil, key: String = "watchlist_items_v2") {
        self.defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.key = key
        self.items = Self.normalizedItems(Self.loadItems(defaults: defaults, key: key, legacyCodesKey: legacyCodesKey))
    }

    /// Appends a code if it is non-empty and not already present.
    public func add(_ code: String) {
        add(code: code)
    }

    /// Appends a code and display name if the code is non-empty and not already present.
    public func add(code: String, name: String = "") {
        guard let normalizedCode = Self.normalizedCode(code),
              !items.contains(where: { $0.code == normalizedCode }) else { return }

        items.append(WatchlistItem(code: normalizedCode, name: name.trimmingCharacters(in: .whitespacesAndNewlines)))
        save()
    }

    /// Removes codes at the given offsets, matching SwiftUI List onDelete semantics.
    public func remove(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where items.indices.contains(index) {
            items.remove(at: index)
        }
        save()
    }

    /// Removes a code if present.
    public func remove(_ code: String) {
        guard let normalizedCode = Self.normalizedCode(code) else {
            return
        }

        items.removeAll { $0.code == normalizedCode }
        save()
    }

    /// Replaces the whole watchlist, preserving first-seen order and removing duplicates.
    public func replace(with newCodes: [String]) {
        items = Self.normalizedItems(newCodes.map { WatchlistItem(code: $0) })
        save()
    }

    /// Replaces the whole watchlist with code and name pairs.
    public func replace(with newItems: [WatchlistItem]) {
        items = Self.normalizedItems(newItems)
        save()
    }

    public func updateName(_ name: String, for code: String) {
        guard let normalizedCode = Self.normalizedCode(code),
              let index = items.firstIndex(where: { $0.code == normalizedCode }) else {
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard items[index].name != trimmedName else {
            return
        }

        items[index].name = trimmedName
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else {
            return
        }

        defaults.set(data, forKey: key)
    }

    private static func loadItems(defaults: UserDefaults, key: String, legacyCodesKey: String) -> [WatchlistItem] {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([WatchlistItem].self, from: data) {
            return decoded
        }

        let legacyCodes = defaults.array(forKey: legacyCodesKey) as? [String] ?? []
        return legacyCodes.map { WatchlistItem(code: $0) }
    }

    private static func normalizedItems(_ items: [WatchlistItem]) -> [WatchlistItem] {
        var seen = Set<String>()
        var result: [WatchlistItem] = []

        for item in items {
            guard let normalizedCode = normalizedCode(item.code),
                  seen.insert(normalizedCode).inserted else {
                continue
            }

            result.append(
                WatchlistItem(
                    code: normalizedCode,
                    name: item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }

        return result
    }

    private static func normalizedCode(_ code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
