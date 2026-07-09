import Foundation
#if ENABLE_LIVE_ACTIVITY && canImport(ActivityKit)
import ActivityKit

@available(iOS 16.2, *)
public enum ChatLiveActivityController {

    public static func start(code: String, name: String, question: String) throws -> Activity<ChatActivityAttributes> {
        let preview = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let attributes = ChatActivityAttributes(code: code, name: name, questionPreview: preview)
        let state = ChatActivityAttributes.ContentState(
            phase: .preparing,
            statusText: "准备发送问题"
        )
        return try Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
    }

    public static func update(
        _ activity: Activity<ChatActivityAttributes>,
        phase: ChatActivityAttributes.ContentState.Phase,
        statusText: String,
        diagnostics: LLMStreamDiagnostics
    ) async {
        let state = ChatActivityAttributes.ContentState(
            phase: phase,
            statusText: statusText,
            receivedCharacters: diagnostics.receivedCharacterCount,
            deltaCount: diagnostics.deltaCount,
            isLikelyBuffered: diagnostics.isLikelyBuffered
        )
        await activity.update(.init(state: state, staleDate: nil))
    }

    public static func end(
        _ activity: Activity<ChatActivityAttributes>,
        succeeded: Bool,
        statusText: String,
        diagnostics: LLMStreamDiagnostics
    ) async {
        let state = ChatActivityAttributes.ContentState(
            phase: succeeded ? .finished : .failed,
            statusText: statusText,
            receivedCharacters: diagnostics.receivedCharacterCount,
            deltaCount: diagnostics.deltaCount,
            isLikelyBuffered: diagnostics.isLikelyBuffered,
            isSettled: true,
            succeeded: succeeded
        )
        await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .default)
    }
}
#endif
