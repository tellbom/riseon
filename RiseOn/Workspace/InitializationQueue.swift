import Foundation

/// One (stock, step) unit of work and its own retry bookkeeping (task.md S4.1).
/// A stock's full pipeline is five of these, one per `InitStep`, always
/// executed in `InitStep.allCases` order.
public struct InitTask: Codable, Equatable, Hashable, Sendable {
    public var code: String
    public var step: InitStep
    public var retries: Int
    public var status: InitTaskStatus

    public init(code: String, step: InitStep, retries: Int = 0, status: InitTaskStatus = .pending) {
        self.code = code
        self.step = step
        self.retries = retries
        self.status = status
    }
}

public enum InitTaskStatus: String, Codable, Equatable, Hashable, Sendable {
    case pending
    case running
    case succeeded
    case failed
}

/// Serial-per-stock, bounded-concurrency-across-stocks initialization queue
/// (task.md S4.1-S4.3, plan.md §6/§11).
///
/// Scope note: this queue only handles scheduling, concurrency, retry/backoff,
/// and crash-resume — it does **not** know about `StockWorkspace`,
/// `ContextPack`, or any of Steps A-E's actual business logic (those belong
/// to S5-S8, which don't exist yet). The real per-step work is injected via
/// `StepExecutor`; a future orchestration layer (or the step executors
/// themselves, once S5-S8 land) is responsible for reading/writing the
/// corresponding `StockWorkspace.state` through `WorkspaceStore`. Keeping the
/// queue itself workspace-agnostic is what makes it testable now with a mock.
public actor InitializationQueue {

    public struct Configuration: Sendable {
        public var maxConcurrentStocks: Int
        public var maxRetriesPerStep: Int
        public var baseBackoffSeconds: Double

        public init(
            maxConcurrentStocks: Int = 3,
            maxRetriesPerStep: Int = 3,
            baseBackoffSeconds: Double = 1.0
        ) {
            self.maxConcurrentStocks = max(1, maxConcurrentStocks)
            self.maxRetriesPerStep = max(0, maxRetriesPerStep)
            self.baseBackoffSeconds = max(0, baseBackoffSeconds)
        }
    }

    public enum Outcome: Sendable, Equatable {
        case succeeded
        case failed(InitStep)
    }

    /// Executes one step for one stock. Throwing means the step failed (the
    /// queue handles retry/backoff on its own); returning normally means it
    /// succeeded. S5-S8 plug the real logic in here; tests use a mock.
    public typealias StepExecutor = @Sendable (_ code: String, _ step: InitStep) async throws -> Void

    private let configuration: Configuration
    private let executeStep: StepExecutor
    private let store: InitQueueStore?

    private var pendingCodes: [String] = []
    private var activeCodes: Set<String> = []
    private var tasksByCode: [String: [InitTask]] = [:]
    private var outcomes: [String: Outcome] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        configuration: Configuration = Configuration(),
        store: InitQueueStore? = nil,
        executeStep: @escaping StepExecutor
    ) {
        self.configuration = configuration
        self.store = store
        self.executeStep = executeStep
    }

    // MARK: - Enqueueing (S4.1)

    /// Adds `code` with a fresh 5-step pipeline. No-op if `code` already has
    /// tasks tracked (in-flight, pending, succeeded, or failed) — call
    /// `retry(_:)` to re-drive a previously-failed one.
    public func enqueue(_ code: String) async {
        guard tasksByCode[code] == nil else { return }
        tasksByCode[code] = InitStep.allCases.map { InitTask(code: code, step: $0) }
        pendingCodes.append(code)
        await persist()
        admitPendingUpToCapacity()
    }

    /// Enqueues several codes at once, preserving the order they're admitted
    /// in once slots free up (task.md S4.1: "批量入队 5 只").
    public func enqueue(_ codes: [String]) async {
        for code in codes {
            await enqueue(code)
        }
    }

    // MARK: - Crash resume (S4.2)

    /// Loads persisted task state and re-admits any stock that was mid-flight
    /// when the process died, resuming from the exact interrupted step —
    /// never restarting from step A. Call once after construction (e.g. at
    /// app launch) if a `store` was provided at `init`.
    ///
    /// A task caught as `.running` at load time (the step that was executing
    /// when the process was killed) is treated as not-yet-confirmed-done and
    /// reset to `.pending` so it's re-attempted. A stock with a `.failed` task
    /// is intentionally **not** re-admitted — task.md S4.3 requires that to
    /// stay stopped until `retry(_:)` is called explicitly.
    public func restoreFromPersistedState() async throws {
        guard let store else { return }
        let restored = try await store.load()
        guard !restored.isEmpty else { return }

        var resumable: [String: [InitTask]] = [:]
        var toReadmit: [String] = []

        for (code, steps) in restored {
            let normalized = steps.map { task -> InitTask in
                var t = task
                if t.status == .running { t.status = .pending }
                return t
            }
            resumable[code] = normalized

            if let failedTask = normalized.first(where: { $0.status == .failed }) {
                outcomes[code] = .failed(failedTask.step)
            } else if normalized.allSatisfy({ $0.status == .succeeded }) {
                outcomes[code] = .succeeded
            } else {
                toReadmit.append(code)
            }
        }

        tasksByCode = resumable
        pendingCodes = toReadmit.sorted()
        admitPendingUpToCapacity()
    }

    // MARK: - Manual retry (S4.3)

    /// Re-drives a stock whose pipeline previously exhausted retries and
    /// stopped. Resets only the step that failed (and its retry count) —
    /// earlier, already-succeeded steps are left untouched, so this resumes
    /// from the failed step rather than redoing everything.
    ///
    /// Returns `false` if `code` isn't currently in a `.failed` outcome (e.g.
    /// unknown code, still running, or already succeeded).
    @discardableResult
    public func retry(_ code: String) async -> Bool {
        guard case .failed(let step)? = outcomes[code],
              var steps = tasksByCode[code],
              let index = steps.firstIndex(where: { $0.step == step }) else {
            return false
        }

        steps[index].status = .pending
        steps[index].retries = 0
        tasksByCode[code] = steps
        outcomes[code] = nil

        if !pendingCodes.contains(code), !activeCodes.contains(code) {
            pendingCodes.append(code)
        }
        await persist()
        admitPendingUpToCapacity()
        return true
    }

    // MARK: - Manual refresh (S12.1)

    public enum RefreshError: Error, Equatable, Sendable {
        /// `code` is currently mid-flight (in `activeCodes`). Resetting its
        /// task list out from under an in-flight `runPipeline` run would
        /// race with that run's own writes — wait for it to finish (or fail)
        /// first, then refresh.
        case alreadyActive
    }

    /// Forces a fully fresh run of all 5 steps for `code` (task.md S12.1),
    /// regardless of its previous outcome — unlike `retry(_:)` (which only
    /// re-drives the step that failed, leaving earlier successes alone),
    /// this resets everything, including steps that had already succeeded.
    /// Used for manual "refresh this stock" (S12.1) and for re-initializing
    /// a workspace whose snapshot has gone stale (S12.2).
    ///
    /// If `code` isn't tracked at all yet, this behaves like `enqueue(_:)` —
    /// "refresh" just means "make sure a fresh run is queued", regardless of
    /// whether one ever ran before.
    @discardableResult
    public func refresh(_ code: String) async throws -> Bool {
        guard !activeCodes.contains(code) else {
            throw RefreshError.alreadyActive
        }

        tasksByCode[code] = InitStep.allCases.map { InitTask(code: code, step: $0) }
        outcomes[code] = nil
        if !pendingCodes.contains(code) {
            pendingCodes.append(code)
        }
        await persist()
        admitPendingUpToCapacity()
        return true
    }

    // MARK: - Observation (for callers and tests)

    public func tasks(for code: String) -> [InitTask]? {
        tasksByCode[code]
    }

    public func outcome(for code: String) -> Outcome? {
        outcomes[code]
    }

    public func activeCount() -> Int {
        activeCodes.count
    }

    public func pendingCount() -> Int {
        pendingCodes.count
    }

    /// Suspends until every enqueued stock has either succeeded or stopped on
    /// a failed step. Intended for tests; real UI code should observe
    /// per-code `outcome(for:)`/`tasks(for:)` instead of blocking.
    public func waitUntilIdle() async {
        if pendingCodes.isEmpty, activeCodes.isEmpty {
            return
        }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    // MARK: - Scheduling core

    /// Admits as many pending codes as there are free slots. Safe to call
    /// redundantly — it's a no-op once slots are full or the queue is empty.
    private func admitPendingUpToCapacity() {
        while activeCodes.count < configuration.maxConcurrentStocks, !pendingCodes.isEmpty {
            let code = pendingCodes.removeFirst()
            activeCodes.insert(code)
            Task { [weak self] in
                await self?.runPipeline(for: code)
            }
        }
    }

    /// Runs one stock's steps strictly in `InitStep.allCases` order, stopping
    /// at the first step that exhausts its retries.
    private func runPipeline(for code: String) async {
        let steps = tasksByCode[code] ?? []
        for index in steps.indices {
            if tasksByCode[code]?[index].status == .succeeded {
                continue // already done before a crash/restore — don't redo it
            }
            let step = steps[index].step
            let succeeded = await runStepWithRetry(code: code, index: index, step: step)
            if !succeeded {
                outcomes[code] = .failed(step)
                finishPipeline(for: code)
                return
            }
        }
        outcomes[code] = .succeeded
        finishPipeline(for: code)
    }

    /// Runs a single step, retrying with exponential backoff up to
    /// `maxRetriesPerStep`. Returns `true` once it succeeds, `false` once
    /// retries are exhausted.
    private func runStepWithRetry(code: String, index: Int, step: InitStep) async -> Bool {
        while true {
            setTaskStatus(code: code, index: index, status: .running)
            await persist()

            do {
                try await executeStep(code, step)
                setTaskStatus(code: code, index: index, status: .succeeded)
                await persist()
                return true
            } catch {
                let attempt = incrementRetries(code: code, index: index)
                if attempt > configuration.maxRetriesPerStep {
                    setTaskStatus(code: code, index: index, status: .failed)
                    await persist()
                    return false
                }
                setTaskStatus(code: code, index: index, status: .pending)
                await persist()

                let delaySeconds = configuration.baseBackoffSeconds * pow(2.0, Double(attempt - 1))
                if delaySeconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                }
            }
        }
    }

    private func finishPipeline(for code: String) {
        activeCodes.remove(code)
        admitPendingUpToCapacity()
        if pendingCodes.isEmpty, activeCodes.isEmpty {
            let waiters = idleWaiters
            idleWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    private func setTaskStatus(code: String, index: Int, status: InitTaskStatus) {
        tasksByCode[code]?[index].status = status
    }

    @discardableResult
    private func incrementRetries(code: String, index: Int) -> Int {
        guard var task = tasksByCode[code]?[index] else { return 0 }
        task.retries += 1
        tasksByCode[code]?[index] = task
        return task.retries
    }

    private func persist() async {
        guard let store else { return }
        try? await store.save(tasksByCode)
    }
}
