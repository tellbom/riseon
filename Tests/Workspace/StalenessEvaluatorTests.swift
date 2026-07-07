import XCTest
@testable import RiseOn

/// Covers task.md S12.2's verification point: staleness fires when the
/// snapshot date is before the most recent trading day, or the snapshot is
/// simply too old, and `StockWorkspace` transitions to `.stale` accordingly.
/// (The UI side of the verification — "UI 出现'数据过期，建议刷新'" — is a
/// later, S13+ concern; this covers the logic UI would react to.)
final class StalenessEvaluatorTests: XCTestCase {

    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: - StalenessEvaluator.isStale

    func test_nilSnapshotDate_isAlwaysStale() {
        XCTAssertTrue(StalenessEvaluator.isStale(
            snapshotDate: nil,
            mostRecentTradingDay: date(2026, 7, 6),
            now: date(2026, 7, 6),
            calendar: calendar
        ))
    }

    func test_snapshotOnMostRecentTradingDay_sameDay_notStale() {
        XCTAssertFalse(StalenessEvaluator.isStale(
            snapshotDate: date(2026, 7, 6),
            mostRecentTradingDay: date(2026, 7, 6),
            now: date(2026, 7, 6),
            calendar: calendar
        ))
    }

    func test_snapshotBeforeMostRecentTradingDay_isStale() {
        // e.g. Friday's snapshot, but Monday is now the most recent trading day.
        XCTAssertTrue(StalenessEvaluator.isStale(
            snapshotDate: date(2026, 7, 3),
            mostRecentTradingDay: date(2026, 7, 6),
            now: date(2026, 7, 6),
            calendar: calendar
        ))
    }

    func test_snapshotMatchesTradingDay_butTooOldByAgeThreshold_isStale() {
        // Snapshot matches the trading day at the time, but `now` is well
        // past it (e.g. app not opened in a while) -- maxAgeInDays=3.
        XCTAssertTrue(StalenessEvaluator.isStale(
            snapshotDate: date(2026, 7, 1),
            mostRecentTradingDay: date(2026, 7, 1),
            now: date(2026, 7, 5), // 4 days later, > 3
            maxAgeInDays: 3,
            calendar: calendar
        ))
    }

    func test_snapshotExactlyAtAgeThreshold_notYetStale() {
        // Exactly 3 days later with maxAgeInDays=3 -> not > 3, so not stale
        // via the age path (boundary case).
        XCTAssertFalse(StalenessEvaluator.isStale(
            snapshotDate: date(2026, 7, 1),
            mostRecentTradingDay: date(2026, 7, 1),
            now: date(2026, 7, 4),
            maxAgeInDays: 3,
            calendar: calendar
        ))
    }

    func test_timeOfDayIgnored_onlyCalendarDayMatters() {
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date(2026, 7, 6))
        components.hour = 23
        components.minute = 59
        let lateSameDay = calendar.date(from: components)!

        XCTAssertFalse(StalenessEvaluator.isStale(
            snapshotDate: date(2026, 7, 6), // midnight
            mostRecentTradingDay: date(2026, 7, 6),
            now: lateSameDay, // 23:59 the same day
            calendar: calendar
        ))
    }

    // MARK: - StockWorkspace.evaluateStaleness

    private func makeReadyWorkspace(snapshotDate: Date) throws -> StockWorkspace {
        var workspace = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh")
        try workspace.transition(to: .initializing)
        try workspace.applyRefreshedPack(
            ContextPack(subject: ContextPackSubject(code: "600519"), dataQuality: DataQuality(level: "good")),
            ruleScore: nil,
            snapshotDate: snapshotDate,
            source: "tencent"
        )
        return workspace
    }

    func test_evaluateStaleness_transitionsReadyToStale_whenStale() throws {
        var workspace = try makeReadyWorkspace(snapshotDate: date(2026, 7, 1))
        XCTAssertEqual(workspace.state, .ready)

        let becameStale = try workspace.evaluateStaleness(mostRecentTradingDay: date(2026, 7, 6), now: date(2026, 7, 6), calendar: calendar)

        XCTAssertTrue(becameStale)
        XCTAssertEqual(workspace.state, .stale)
    }

    func test_evaluateStaleness_leavesReadyAlone_whenNotStale() throws {
        var workspace = try makeReadyWorkspace(snapshotDate: date(2026, 7, 6))

        let becameStale = try workspace.evaluateStaleness(mostRecentTradingDay: date(2026, 7, 6), now: date(2026, 7, 6), calendar: calendar)

        XCTAssertFalse(becameStale)
        XCTAssertEqual(workspace.state, .ready, "must remain ready, not be forced into any transition")
    }

    func test_evaluateStaleness_noOpWhenNotReadyOrPartial() throws {
        var workspace = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh") // .uninitialized

        let becameStale = try workspace.evaluateStaleness(mostRecentTradingDay: date(2026, 7, 6), now: date(2026, 7, 6), calendar: calendar)

        XCTAssertFalse(becameStale)
        XCTAssertEqual(workspace.state, .uninitialized, "staleness doesn't apply before a workspace is ever ready")
    }

    func test_evaluateStaleness_worksFromPartialToo() throws {
        var workspace = StockWorkspace(code: "600519", name: "贵州茅台", market: "sh")
        try workspace.transition(to: .initializing)
        try workspace.applyRefreshedPack(
            ContextPack(subject: ContextPackSubject(code: "600519"), dataQuality: DataQuality(level: "poor")),
            ruleScore: nil,
            snapshotDate: date(2026, 7, 1),
            source: "tencent"
        )
        XCTAssertEqual(workspace.state, .partial)

        let becameStale = try workspace.evaluateStaleness(mostRecentTradingDay: date(2026, 7, 6), now: date(2026, 7, 6), calendar: calendar)

        XCTAssertTrue(becameStale)
        XCTAssertEqual(workspace.state, .stale)
    }
}
