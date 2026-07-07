import Foundation
#if ENABLE_LIVE_ACTIVITY && canImport(ActivityKit)
import ActivityKit

/// Drives a `WorkspaceInitActivityAttributes` Live Activity from
/// `InitializationQueue` state (task.md S14.2). Lives in the main app
/// target (unlike the widget UI itself, which needs the Widget Extension
/// target — see `WorkspaceInitActivityAttributes`'s doc comment for the
/// Xcode setup this can't do on its own).
///
/// Same verification caveat as `WorkspaceInitActivityAttributes`: no
/// ActivityKit in this sandbox, so this is an uncompiled first draft.
@available(iOS 16.2, *)
public enum WorkspaceLiveActivityController {

    /// Starts a new Live Activity for `code`, at 0 of `totalSteps` complete.
    public static func start(
        code: String,
        name: String,
        totalSteps: Int = InitStep.allCases.count
    ) throws -> Activity<WorkspaceInitActivityAttributes> {
        let attributes = WorkspaceInitActivityAttributes(code: code, name: name)
        let state = WorkspaceInitActivityAttributes.ContentState(
            completedSteps: 0,
            totalSteps: totalSteps,
            currentStepName: InitStep.allCases.first?.displayName ?? "",
            isSettled: false,
            succeeded: false
        )
        return try Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
    }

    /// Refreshes an in-progress activity from the queue's current task list
    /// for this stock — call this from the same poll loop
    /// `InitProgressViewModel` (S13) already runs, so there's only one
    /// "watch the queue" mechanism, not two competing ones.
    public static func update(
        _ activity: Activity<WorkspaceInitActivityAttributes>,
        tasks: [InitTask]
    ) async {
        let completed = tasks.filter { $0.status == .succeeded }.count
        let runningStep = tasks.first { $0.status == .running }?.step
        let state = WorkspaceInitActivityAttributes.ContentState(
            completedSteps: completed,
            totalSteps: tasks.count,
            currentStepName: runningStep?.displayName ?? "",
            isSettled: false,
            succeeded: false
        )
        await activity.update(.init(state: state, staleDate: nil))
    }

    /// Ends the activity once `InitializationQueue` reports a settled
    /// outcome for this stock.
    public static func end(
        _ activity: Activity<WorkspaceInitActivityAttributes>,
        outcome: InitializationQueue.Outcome,
        totalSteps: Int = InitStep.allCases.count
    ) async {
        let succeeded: Bool
        let completedSteps: Int
        switch outcome {
        case .succeeded:
            succeeded = true
            completedSteps = totalSteps
        case .failed:
            succeeded = false
            completedSteps = activity.content.state.completedSteps
        }

        let state = WorkspaceInitActivityAttributes.ContentState(
            completedSteps: completedSteps,
            totalSteps: totalSteps,
            currentStepName: "",
            isSettled: true,
            succeeded: succeeded
        )
        await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .default)
    }
}
#endif
