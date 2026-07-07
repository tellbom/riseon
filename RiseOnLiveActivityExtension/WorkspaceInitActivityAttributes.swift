import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct WorkspaceInitActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var completedSteps: Int
        var totalSteps: Int
        var currentStepName: String
        var isSettled: Bool
        var succeeded: Bool
    }

    var code: String
    var name: String
}
