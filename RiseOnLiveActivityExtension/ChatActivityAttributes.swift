import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct ChatActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Hashable, Sendable {
            case preparing
            case searching
            case waitingForModel
            case streaming
            case finished
            case failed
        }

        var phase: Phase
        var statusText: String
        var receivedCharacters: Int
        var deltaCount: Int
        var isLikelyBuffered: Bool
        var isSettled: Bool
        var succeeded: Bool
    }

    var code: String
    var name: String
    var questionPreview: String
}
