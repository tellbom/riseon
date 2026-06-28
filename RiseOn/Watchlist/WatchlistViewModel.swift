import Combine
import Foundation

@MainActor
final class WatchlistViewModel: ObservableObject {
    @Published private(set) var codes: [String] = []
    @Published private(set) var addError: String?

    private let store: WatchlistStore

    init(store: WatchlistStore) {
        self.store = store
        store.$codes
            .assign(to: &$codes)
    }

    func add(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            addError = "请输入股票代码"
            return
        }

        guard StockSymbol(code: trimmed) != nil else {
            addError = "无效代码：须以 0/3/4/6/8 开头"
            return
        }

        guard !codes.contains(trimmed) else {
            addError = "\(trimmed) 已在自选列表中"
            return
        }

        store.add(trimmed)
        addError = nil
    }

    func remove(at offsets: IndexSet) {
        store.remove(at: offsets)
    }

    func clearError() {
        addError = nil
    }
}
