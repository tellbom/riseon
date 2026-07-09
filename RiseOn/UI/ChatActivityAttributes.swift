import Foundation
#if ENABLE_LIVE_ACTIVITY && canImport(ActivityKit)
import ActivityKit

@available(iOS 16.1, *)
public struct ChatActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public enum Phase: String, Codable, Hashable, Sendable {
            case preparing
            case searching
            case waitingForModel
            case streaming
            case finished
            case failed
        }

        public var phase: Phase
        public var statusText: String
        public var receivedCharacters: Int
        public var deltaCount: Int
        public var isLikelyBuffered: Bool
        public var isSettled: Bool
        public var succeeded: Bool

        public init(
            phase: Phase,
            statusText: String,
            receivedCharacters: Int = 0,
            deltaCount: Int = 0,
            isLikelyBuffered: Bool = false,
            isSettled: Bool = false,
            succeeded: Bool = false
        ) {
            self.phase = phase
            self.statusText = statusText
            self.receivedCharacters = receivedCharacters
            self.deltaCount = deltaCount
            self.isLikelyBuffered = isLikelyBuffered
            self.isSettled = isSettled
            self.succeeded = succeeded
        }
    }

    public var code: String
    public var name: String
    public var questionPreview: String

    public init(code: String, name: String, questionPreview: String) {
        self.code = code
        self.name = name
        self.questionPreview = questionPreview
    }
}
#endif
