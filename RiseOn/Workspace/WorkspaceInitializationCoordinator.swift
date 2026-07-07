import Foundation

/// Wires S5 (daily bars + realtime overlay), S6 (technical indicators),
/// S7 (rule scoring), and S8 (context pack building) into a single
/// `InitializationQueue.StepExecutor` (S4), and provides the "create a
/// workspace and kick off initialization" entry point task.md S16.1 needs.
///
/// This is the piece every prior S-task's scope notes kept pointing at and
/// deferring ("that's a later orchestration task, not in scope here") —
/// S16's MVP acceptance criteria can't actually be exercised end-to-end
/// without it, so it's built now rather than leaving the acceptance review
/// checking disconnected parts.
///
/// **Two different resilience mechanisms, on purpose** (plan.md, task.md
/// S15.1 vs S4.3): `fetchDailyBars`/`overlayRealtime` are network-dependent
/// and **never throw** — a failure is caught and recorded as a
/// `...FetchFailed` flag, so the pipeline continues on to build a
/// degraded-but-honest Pack (S15.1's "不阻塞 ready"). `computeIndicators`/
/// `computeRuleScore`/`buildPack` are pure computation/disk-write with no
/// network involved; if *those* throw, that's a real bug, not expected
/// flakiness, so they're left to propagate into `InitializationQueue`'s own
/// retry/backoff and eventual `.failed(step)` (S4.3) — retrying a network
/// call that already failed twice (`TencentDailyProvider`'s own S5.3 retry)
/// rarely helps, but retrying a transient computation hiccup might.
public actor WorkspaceInitializationCoordinator {

    public enum CoordinatorError: Error, Equatable, Sendable {
        case workspaceNotFound(String)
        case missingStagingData(String)
    }

    /// Per-code scratch data threaded between steps — `InitializationQueue`'s
    /// `StepExecutor` signature is just `(code, step) async throws -> Void`
    /// with no return value to pass data forward, so this actor's own state
    /// is where Step A's output becomes Step B's input, and so on. Cleared
    /// once Step E finishes (succeeds or gives up).
    private struct Staging {
        var rawBars: [DailyBar] = []
        var dailyBarsFetchFailed = false
        var overlaidBars: [DailyBar] = []
        var overlayWarnings: [String] = []
        var quote: Quote?
        var quoteFetchFailed = false
        var technicalSeries: TechnicalIndicators.Series?
        var latestSignals: TechnicalIndicators.LatestSignals?
        var ruleScore: RuleScore?
        var windowReturns: [Int: Double] = [:]
        var rangePosition20d: Double?
    }

    private let workspaceStore: WorkspaceStore
    private let dailyProvider: any DailyBarsProvider
    private let quoteProvider: any QuoteProvider
    private let isTradingDayToday: @Sendable () -> Bool
    private var staging: [String: Staging] = [:]

    public init(
        workspaceStore: WorkspaceStore,
        dailyProvider: any DailyBarsProvider = TencentDailyProvider(),
        quoteProvider: any QuoteProvider = TencentQuoteProvider(),
        isTradingDayToday: @escaping @Sendable () -> Bool = WorkspaceInitializationCoordinator.defaultIsTradingDayToday
    ) {
        self.workspaceStore = workspaceStore
        self.dailyProvider = dailyProvider
        self.quoteProvider = quoteProvider
        self.isTradingDayToday = isTradingDayToday
    }

    /// Weekday-only trading-day approximation (Mon-Fri, no public-holiday
    /// calendar) — a real trading calendar doesn't exist yet in this
    /// project (`RealtimeOverlay`'s own doc comment already flags this gap
    /// from S5.2). Good enough for MVP; wrong on public holidays.
    public static func defaultIsTradingDayToday() -> Bool {
        let weekday = Calendar(identifier: .gregorian).component(.weekday, from: Date())
        return weekday != 1 && weekday != 7 // not Sunday(1) or Saturday(7)
    }

    // MARK: - Entry point (task.md S16.1: "从自选股一键建 Workspace")

    /// Creates a brand-new `StockWorkspace` (or reuses an already-created
    /// but still-`.uninitialized` one) and enqueues it on `queue`. A no-op
    /// if the workspace already exists and has moved past `.uninitialized`
    /// — this is specifically the *first* initialization; re-driving an
    /// existing workspace is `InitializationQueue.refresh(_:)` (S12.1)'s job.
    @discardableResult
    public func startInitialization(
        code: String,
        name: String,
        market: String,
        queue: InitializationQueue
    ) async throws -> Bool {
        var workspace = try await workspaceStore.load(code: code)
            ?? StockWorkspace(code: code, name: name, market: market)

        guard workspace.state == .uninitialized else {
            return false
        }

        try workspace.transition(to: .initializing)
        try await workspaceStore.save(workspace)
        await queue.enqueue(code)
        return true
    }

    // MARK: - StepExecutor (task.md S4.1's injection point)

    /// Returns a closure suitable for `InitializationQueue.init(executeStep:)`,
    /// bound to this coordinator instance.
    public func stepExecutor() -> InitializationQueue.StepExecutor {
        { [weak self] code, step in
            guard let self else { return }
            try await self.performStep(code: code, step: step)
        }
    }

    private func performStep(code: String, step: InitStep) async throws {
        switch step {
        case .fetchDailyBars:
            await fetchDailyBars(code: code)
        case .overlayRealtime:
            await overlayRealtime(code: code)
        case .computeIndicators:
            try computeIndicators(code: code)
        case .computeRuleScore:
            try computeRuleScore(code: code)
        case .buildPack:
            try await buildAndPersistPack(code: code)
        }
    }

    // MARK: - Step A

    private func fetchDailyBars(code: String) async {
        var entry = staging[code] ?? Staging()

        guard let fullSymbol = ACodeResolver.fullSymbol(for: code) else {
            // Structural: this code can't be resolved to a Tencent symbol at
            // all. Not a fetch failure (we never attempted a network call)
            // -- retrying wouldn't help, so this stays `false`/empty rather
            // than looping S4.3's backoff on something permanent.
            entry.rawBars = []
            entry.dailyBarsFetchFailed = false
            staging[code] = entry
            return
        }

        let now = Date()
        let end = Self.dateString(now)
        let start = Self.dateString(Calendar.current.date(byAdding: .day, value: -400, to: now) ?? now)

        do {
            entry.rawBars = try await dailyProvider.fetchDailyBars(fullSymbol: fullSymbol, start: start, end: end, lookback: 320)
            entry.dailyBarsFetchFailed = false
        } catch {
            // `TencentDailyProvider` already retries once internally
            // (S5.3). Reaching here means that already failed -- treat as
            // graceful degradation (S15.1), not a queue-level retry target.
            entry.rawBars = []
            entry.dailyBarsFetchFailed = true
        }
        staging[code] = entry
    }

    // MARK: - Step B

    private func overlayRealtime(code: String) async {
        var entry = staging[code] ?? Staging()

        guard let symbol = StockSymbol(code: code) else {
            // `StockSymbol` can't represent this code (e.g. 5/9-prefixed) --
            // a structural gap documented since S5 (the existing
            // `TencentQuoteProvider` only accepts `StockSymbol`, and that
            // file is off-limits to modify per S1.1). Not a fetch failure.
            entry.overlaidBars = entry.rawBars
            entry.overlayWarnings = entry.rawBars.isEmpty
                ? []
                : [ContextPackWarningKey.intradayVolumeOverlaySkipped, ContextPackWarningKey.realtimeOverlayUnavailable]
            entry.quote = nil
            entry.quoteFetchFailed = false
            staging[code] = entry
            return
        }

        do {
            let quote = try await quoteProvider.fetchQuote(for: symbol)
            entry.quote = quote
            entry.quoteFetchFailed = false
            let result = RealtimeOverlay.apply(
                to: entry.rawBars,
                quote: quote,
                isTradingDay: isTradingDayToday(),
                today: Self.dateString(Date())
            )
            entry.overlaidBars = result.bars
            entry.overlayWarnings = result.warnings
        } catch {
            entry.quote = nil
            entry.quoteFetchFailed = true
            entry.overlaidBars = entry.rawBars
            entry.overlayWarnings = entry.rawBars.isEmpty
                ? []
                : [ContextPackWarningKey.intradayVolumeOverlaySkipped, ContextPackWarningKey.realtimeOverlayUnavailable]
        }
        staging[code] = entry
    }

    // MARK: - Step C

    private func computeIndicators(code: String) throws {
        guard var entry = staging[code] else {
            throw CoordinatorError.missingStagingData(code)
        }
        let bars = entry.overlaidBars
        let series = TechnicalIndicators.computeAll(bars: bars)
        entry.technicalSeries = series
        entry.latestSignals = TechnicalIndicators.latestSignals(bars: bars, series: series)
        entry.windowReturns = FactorWindows.windowReturns(bars: bars)
        entry.rangePosition20d = FactorWindows.rangePosition(bars: bars)
        staging[code] = entry
    }

    // MARK: - Step D

    private func computeRuleScore(code: String) throws {
        guard var entry = staging[code] else {
            throw CoordinatorError.missingStagingData(code)
        }
        entry.ruleScore = RuleScoreEngine.analyze(bars: entry.overlaidBars, code: code)
        staging[code] = entry
    }

    // MARK: - Step E

    private func buildAndPersistPack(code: String) async throws {
        guard let entry = staging[code] else {
            throw CoordinatorError.missingStagingData(code)
        }
        guard var workspace = try await workspaceStore.load(code: code) else {
            throw CoordinatorError.workspaceNotFound(code)
        }

        let pack = ContextPackBuilder.build(.init(
            subject: ContextPackSubject(code: code, stockName: workspace.name, market: workspace.market),
            dailyBars: entry.overlaidBars,
            overlayWarnings: entry.overlayWarnings,
            quote: entry.quote,
            quoteFetchFailed: entry.quoteFetchFailed,
            dailyBarsFetchFailed: entry.dailyBarsFetchFailed,
            technicalSeries: entry.technicalSeries,
            latestSignals: entry.latestSignals,
            ruleScore: entry.ruleScore,
            windowReturns: entry.windowReturns,
            rangePosition20d: entry.rangePosition20d
        ))

        try workspace.applyRefreshedPack(pack, ruleScore: entry.ruleScore, snapshotDate: Date(), source: "tencent")
        try await workspaceStore.save(workspace)
        staging[code] = nil
    }

    // MARK: - Helpers

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
