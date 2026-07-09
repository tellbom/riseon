import Foundation

public enum WatchlistSyncPayload {
    public static let itemsKey = "watchlist_items"
    public static let legacyCodesKey = "watchlist"

    public static func context(for items: [WatchlistItem]) -> [String: Any] {
        [
            itemsKey: items.map { item in
                [
                    "code": item.code,
                    "name": item.name
                ]
            }
        ]
    }

    public static func items(from context: [String: Any]) -> [WatchlistItem]? {
        if let payload = context[itemsKey] as? [[String: String]] {
            return payload.compactMap { dictionary in
                guard let code = dictionary["code"] else {
                    return nil
                }
                return WatchlistItem(code: code, name: dictionary["name"] ?? "")
            }
        }

        if let codes = context[legacyCodesKey] as? [String] {
            return codes.map { WatchlistItem(code: $0) }
        }

        return nil
    }
}
