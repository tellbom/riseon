import Testing
@testable import RiseOn

struct WatchlistSyncPayloadTests {
    @Test
    func encodesAndDecodesWatchlistItems() {
        let items = [
            WatchlistItem(code: "600519", name: "贵州茅台"),
            WatchlistItem(code: "000001", name: "平安银行")
        ]

        let context = WatchlistSyncPayload.context(for: items)

        #expect(WatchlistSyncPayload.items(from: context) == items)
    }

    @Test
    func decodesLegacyCodePayload() {
        let context: [String: Any] = [
            WatchlistSyncPayload.legacyCodesKey: ["600519", "000001"]
        ]

        #expect(
            WatchlistSyncPayload.items(from: context) == [
                WatchlistItem(code: "600519"),
                WatchlistItem(code: "000001")
            ]
        )
    }
}
