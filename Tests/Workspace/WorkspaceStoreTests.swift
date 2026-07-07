import XCTest
@testable import RiseOn

/// Covers task.md S3.1's verification point: "建两只股票→互不干扰→重启后仍在"
/// (create two stocks -> no interference -> still there after restart).
final class WorkspaceStoreTests: XCTestCase {

    /// Creates a store rooted at a fresh temp directory and schedules its
    /// cleanup, so tests never touch the real Application Support directory
    /// or leak files between runs.
    private func makeTempStore() throws -> WorkspaceStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceStoreTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return try WorkspaceStore(directory: directory)
    }

    func test_saveThenLoad_roundTrips() async throws {
        let store = try makeTempStore()

        var workspace = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh")
        workspace.ruleScore = RuleScore(code: "600519", signalScore: 80)
        try workspace.transition(to: .initializing)
        try workspace.transition(to: .ready)

        try await store.save(workspace)
        let loaded = try await store.load(code: "600519")

        XCTAssertEqual(loaded, workspace)
    }

    func test_loadMissingCode_returnsNilWithoutThrowing() async throws {
        let store = try makeTempStore()
        let loaded = try await store.load(code: "999999")
        XCTAssertNil(loaded)
    }

    func test_twoStocks_doNotInterfereWithEachOther() async throws {
        let store = try makeTempStore()

        var a = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh")
        a.ruleScore = RuleScore(code: "600519", signalScore: 10)
        var b = StockWorkspace(code: "000001", name: "平安银行", market: "sz")
        b.ruleScore = RuleScore(code: "000001", signalScore: 90)

        try await store.save(a)
        try await store.save(b)

        let loadedA = try await store.load(code: "600519")
        let loadedB = try await store.load(code: "000001")

        XCTAssertEqual(loadedA?.name, "贵州茅台")
        XCTAssertEqual(loadedA?.ruleScore?.signalScore, 10)
        XCTAssertEqual(loadedB?.name, "平安银行")
        XCTAssertEqual(loadedB?.ruleScore?.signalScore, 90)
    }

    func test_deletingOneStock_leavesTheOtherIntact() async throws {
        let store = try makeTempStore()

        try await store.save(StockWorkspace(code: "600519", name: "贵州茅台", market: "sh"))
        try await store.save(StockWorkspace(code: "000001", name: "平安银行", market: "sz"))

        try await store.delete(code: "600519")

        let goneA = try await store.load(code: "600519")
        let stillB = try await store.load(code: "000001")

        XCTAssertNil(goneA)
        XCTAssertNotNil(stillB)
    }

    func test_deleteMissingCode_doesNotThrow() async throws {
        let store = try makeTempStore()
        try await store.delete(code: "not_saved")
    }

    func test_overwritingExistingCode_replacesContentInPlace() async throws {
        let store = try makeTempStore()

        var workspace = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh")
        workspace.ruleScore = RuleScore(code: "600519", signalScore: 10)
        try await store.save(workspace)

        workspace.ruleScore = RuleScore(code: "600519", signalScore: 55)
        try await store.save(workspace)

        let loaded = try await store.load(code: "600519")
        XCTAssertEqual(loaded?.ruleScore?.signalScore, 55)

        // Overwriting must not create a second file for the same code.
        let codes = try await store.allCodes()
        XCTAssertEqual(codes, ["600519"])
    }

    func test_allCodes_listsEverySavedWorkspace_sorted() async throws {
        let store = try makeTempStore()

        try await store.save(StockWorkspace(code: "600519", name: "贵州茅台", market: "sh"))
        try await store.save(StockWorkspace(code: "000001", name: "平安银行", market: "sz"))
        try await store.save(StockWorkspace(code: "300059", name: "东方财富", market: "sz"))

        let codes = try await store.allCodes()
        XCTAssertEqual(codes, ["000001", "300059", "600519"])
    }

    func test_loadAll_returnsEveryPersistedWorkspace() async throws {
        let store = try makeTempStore()

        try await store.save(StockWorkspace(code: "600519", name: "贵州茅台", market: "sh"))
        try await store.save(StockWorkspace(code: "000001", name: "平安银行", market: "sz"))

        let all = try await store.loadAll()
        XCTAssertEqual(Set(all.map(\.code)), Set(["600519", "000001"]))
    }

    /// Reproduces the exact real-world failure: a file saved under an older
    /// `StockWorkspace` schema (missing keys the current `Codable`
    /// conformance requires, e.g. a pre-multi-thread-chat `chatSession`
    /// layout instead of today's `chatThreads`/`activeChatThreadID`) must
    /// not surface as "the data couldn't be read because it is missing" to
    /// every stock -- `load` should treat it like no workspace was ever
    /// saved, and clear the stale file so it doesn't keep failing.
    func test_loadingAFileWithAnOutdatedSchema_returnsNilInsteadOfThrowing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceStoreTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let staleFile = directory.appendingPathComponent("600519.json")
        let outdatedSchema = #"{"code":"600519","name":"贵州茅台","market":"sh","state":"uninitialized","chatSession":{"code":"600519","messages":[]},"meta":{"source":""}}"#
        try outdatedSchema.data(using: .utf8)!.write(to: staleFile)

        let store = try WorkspaceStore(directory: directory)
        let loaded = try await store.load(code: "600519")

        XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFile.path), "the stale file should be cleared so it doesn't keep failing to decode")
    }

    /// A fresh `WorkspaceStore` instance pointed at the same directory stands
    /// in for "app restart" — nothing is held in memory between saving and
    /// re-opening, only the files on disk.
    func test_persistsAcrossFreshStoreInstance_simulatingRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceStoreTests-restart-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        do {
            let store = try WorkspaceStore(directory: directory)
            let workspace = StockWorkspace(code: "300059", name: "东方财富", market: "sz")
            try await store.save(workspace)
        }

        let reopened = try WorkspaceStore(directory: directory)
        let loaded = try await reopened.load(code: "300059")
        XCTAssertEqual(loaded?.name, "东方财富")
    }
}
