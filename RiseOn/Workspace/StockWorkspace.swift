import Foundation

/// One stock's isolated workspace: identity + initialization state machine.
///
/// State machine (plan.md §5-6, task.md S2.1):
/// `uninitialized -> initializing -> ready -> (stale | partial)`, with a
/// retryable `failed(step)` state. Legal transitions are enforced by
/// `WorkspaceState.canTransition(to:)` — see that type for the full graph.
///
/// This only defines the *shape* (S2.1/S2.2). The actual initialization
/// pipeline (S4), analytics (S6/S7), and pack building (S8) are implemented
/// in later tasks and populate `contextPack`/`ruleScore` once ready.
public struct StockWorkspace: Codable, Equatable, Sendable {
    /// Normalized A-share code, e.g. "600519". Use `ACodeResolver` (S2.3) to
    /// derive the market/prefix — do not reuse `StockSymbol.swift` here.
    public var code: String
    public var name: String
    public var market: String

    public private(set) var state: WorkspaceState

    public var contextPack: ContextPack?
    public var ruleScore: RuleScore?
    public var chatSession: ChatSession
    public var meta: WorkspaceMeta

    public init(code: String, name: String, market: String) {
        self.code = code
        self.name = name
        self.market = market
        self.state = .uninitialized
        self.contextPack = nil
        self.ruleScore = nil
        self.chatSession = ChatSession(code: code, messages: [])
        self.meta = WorkspaceMeta(snapshotDate: nil, source: "", quality: nil)
    }

    /// Attempts to move to `next`. Throws `WorkspaceTransitionError.illegal` if the
    /// transition isn't in `WorkspaceState.canTransition(to:)`'s legal graph.
    @discardableResult
    public mutating func transition(to next: WorkspaceState) throws -> WorkspaceState {
        guard state.canTransition(to: next) else {
            throw WorkspaceTransitionError.illegal(from: state, to: next)
        }
        state = next
        return state
    }
}

/// Workspace lifecycle states (plan.md §5).
public enum WorkspaceState: Equatable, Codable, Sendable {
    case uninitialized
    case initializing
    case ready
    case stale
    case partial
    case failed(InitStep)

    /// Whether moving from `self` to `next` is a legal transition.
    ///
    /// Graph:
    /// - `uninitialized -> initializing` (first run)
    /// - `initializing -> ready` (all steps A-E succeeded, no degraded core blocks)
    /// - `initializing -> partial` (steps completed but a core block degraded/failed,
    ///   still usable for Q&A — S15.1's "部分就绪")
    /// - `initializing -> failed(step)` (a step failed critically, retryable — S4.3)
    /// - `ready -> stale`, `partial -> stale` (snapshot aged out — S12.2)
    /// - `ready|partial|stale|failed -> initializing` (manual refresh / retry — S12.1/S4.3)
    public func canTransition(to next: WorkspaceState) -> Bool {
        switch (self, next) {
        case (.uninitialized, .initializing):
            return true
        case (.initializing, .ready):
            return true
        case (.initializing, .partial):
            return true
        case (.initializing, .failed):
            return true
        case (.ready, .stale):
            return true
        case (.partial, .stale):
            return true
        case (.ready, .initializing):
            return true
        case (.partial, .initializing):
            return true
        case (.stale, .initializing):
            return true
        case (.failed, .initializing):
            return true
        default:
            return false
        }
    }
}

/// The five idempotent, retryable initialization steps (plan.md §6, Step F
/// "就绪" is the terminal `.ready` state, not a step here).
public enum InitStep: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case fetchDailyBars      // Step A
    case overlayRealtime     // Step B
    case computeIndicators   // Step C
    case computeRuleScore    // Step D
    case buildPack           // Step E
}

public enum WorkspaceTransitionError: Error, Equatable {
    case illegal(from: WorkspaceState, to: WorkspaceState)
}
