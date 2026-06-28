import Combine
import Foundation

@MainActor
final class WatchlistViewModel: ObservableObject {
    @Published private(set) var items: [WatchlistItem] = []
    @Published private(set) var addError: String?

    private let store: WatchlistStore

    var codes: [String] {
        items.map(\.code)
    }

    init(store: WatchlistStore) {
        self.store = store
        store.$items
            .assign(to: &$items)
    }

    func add(code: String) {
        add(code: code, name: "")
    }

    func add(code: String, name: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            addError = "请输入股票代码"
            return
        }

        guard StockSymbol(code: trimmed) != nil else {
            addError = "无效代码：须以 0/3/4/6/8 开头"
            return
        }

        guard !items.contains(where: { $0.code == trimmed }) else {
            addError = "\(trimmed) 已在自选列表中"
            return
        }

        store.add(code: trimmed, name: name)
        addError = nil
    }

    func remove(at offsets: IndexSet) {
        store.remove(at: offsets)
    }

    func clearError() {
        addError = nil
    }
}
