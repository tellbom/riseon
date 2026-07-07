import Foundation
import Combine

/// Observes one stock's initialization progress in `InitializationQueue`
/// (task.md S13.1) and exposes it to SwiftUI.
///
/// **Why polling, not a push/subscribe mechanism**: `InitializationQueue`
/// (S4) only exposes pull-based queries (`tasks(for:)`/`outcome(for:)`) —
/// deliberately so, to keep that actor's already-tested core scheduling
/// logic untouched here. Initialization is a short, bounded, foreground-only
/// operation (plan.md §12: never a background compute container), so a
/// lightweight poll loop for the few seconds it takes is a reasonable,
/// simple choice — not a workaround for a missing capability.
///
/// **Scope boundary**: this only *observes* the queue. It does not touch
/// `StockWorkspace`/`WorkspaceStore` — wiring "queue settled -> update
/// workspace state" is orchestration logic for a later task, same reasoning
/// as `InitializationQueue` itself staying workspace-agnostic (S4's own
/// scope note).
@MainActor
public final class InitProgressViewModel: ObservableObject {
    @Published public private(set) var tasks: [InitTask] = []
    @Published public private(set) var outcome: InitializationQueue.Outcome?
    @Published public private(set) var isRetrying: Bool = false

    public let code: String
    private let queue: InitializationQueue
    private let pollIntervalNanoseconds: UInt64

    public init(code: String, queue: InitializationQueue, pollIntervalNanoseconds: UInt64 = 250_000_000) {
        self.code = code
        self.queue = queue
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
    }

    /// Polls until this stock's pipeline settles (succeeded, or stopped on
    /// a failed step), refreshing `tasks`/`outcome` each tick. Meant to be
    /// driven by SwiftUI's `.task { await viewModel.observe() }`, which
    /// cancels this automatically when the view disappears — no manual
    /// start/stop bookkeeping needed.
    public func observe() async {
        while !Task.isCancelled {
            await refreshSnapshot()
            if outcome != nil {
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }

    public func refreshSnapshot() async {
        tasks = await queue.tasks(for: code) ?? []
        outcome = await queue.outcome(for: code)
    }

    /// Retries this stock's pipeline from wherever it stopped (task.md
    /// S13.1's "单步失败可点重试恢复"), then resumes tracking progress
    /// until it settles again. Safe to call repeatedly (e.g. the person
    /// taps "retry" again after another failure).
    public func retry() async {
        guard !isRetrying else { return }
        isRetrying = true
        defer { isRetrying = false }

        _ = await queue.retry(code)
        await observe() // `queue.retry` clears the settled outcome, so this resumes polling
    }
}
