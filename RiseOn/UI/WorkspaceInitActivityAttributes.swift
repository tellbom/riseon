import Foundation
#if ENABLE_LIVE_ACTIVITY && canImport(ActivityKit)
import ActivityKit

/// Live Activity attributes for showing initialization progress on the Lock
/// Screen / Dynamic Island (task.md S14.2). Display-only, per plan.md §12's
/// hard boundary — this struct and its `ContentState` only ever *mirror*
/// `InitializationQueue` state that already exists; nothing here computes
/// anything or keeps the app alive in the background.
///
/// **Xcode setup this file alone can't do**: `ActivityAttributes` types must
/// be compiled into *both* the main app target and a Widget Extension
/// target — that's an Xcode project/target configuration step (Product ▸
/// New Target ▸ Widget Extension, check "Include Live Activity"), not
/// something achievable by dropping in a source file. This file is written
/// assuming that target exists; Codex/you still need to create it and add
/// this file (plus `WorkspaceLiveActivityWidget.swift`) to its membership.
///
/// **Verification caveat**: unlike the rest of this project, `ActivityKit`
/// isn't available in this sandbox at all (no Apple SDK), so none of this
/// file could be compiled, traced through, or cross-checked the way the
/// Analytics/Context/QA code was. Treat this as a first draft to compile
/// and correct in Xcode, not something with the same confidence level as
/// the rest of the S1-S15 delivery.
@available(iOS 16.1, *)
public struct WorkspaceInitActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var completedSteps: Int
        public var totalSteps: Int
        public var currentStepName: String
        public var isSettled: Bool
        public var succeeded: Bool

        public init(
            completedSteps: Int,
            totalSteps: Int,
            currentStepName: String,
            isSettled: Bool,
            succeeded: Bool
        ) {
            self.completedSteps = completedSteps
            self.totalSteps = totalSteps
            self.currentStepName = currentStepName
            self.isSettled = isSettled
            self.succeeded = succeeded
        }
    }

    public var code: String
    public var name: String

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }
}
#endif
