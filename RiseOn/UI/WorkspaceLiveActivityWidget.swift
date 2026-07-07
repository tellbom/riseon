import SwiftUI
#if ENABLE_LIVE_ACTIVITY && WIDGET_EXTENSION && canImport(ActivityKit) && canImport(WidgetKit)
import ActivityKit
import WidgetKit

/// The actual Live Activity presentation (task.md S14.2) — Lock Screen
/// banner + Dynamic Island regions for `WorkspaceInitActivityAttributes`.
///
/// **This file belongs in a Widget Extension target, not the main app
/// target.** Codex/you need to: Xcode ▸ File ▸ New ▸ Target ▸ Widget
/// Extension ▸ check "Include Live Activity" ▸ add this file and
/// `WorkspaceInitActivityAttributes.swift` to that target's membership
/// (the attributes file needs to be in *both* the app and widget targets;
/// this file only needs the widget target). That target creation step is
/// project configuration this sandbox has no way to perform — there's no
/// `.xcodeproj` here to add a target to.
///
/// Same caveat as the rest of the Live Activity code: no ActivityKit/
/// WidgetKit available in this sandbox, so this has not been compiled —
/// treat it as a starting sketch, not verified code.
@available(iOS 16.2, *)
struct WorkspaceInitActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkspaceInitActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.name)
                        .font(.caption)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.completedSteps)/\(context.state.totalSteps)")
                        .font(.caption)
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.isSettled ? (context.state.succeeded ? "初始化完成" : "初始化失败") : context.state.currentStepName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: compactIconName(for: context.state))
            } compactTrailing: {
                Text("\(context.state.completedSteps)/\(context.state.totalSteps)")
                    .font(.caption2)
                    .monospacedDigit()
            } minimal: {
                Image(systemName: compactIconName(for: context.state))
            }
        }
    }

    private func compactIconName(for state: WorkspaceInitActivityAttributes.ContentState) -> String {
        guard state.isSettled else { return "arrow.triangle.2.circlepath" }
        return state.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }
}

@available(iOS 16.2, *)
private struct LockScreenView: View {
    let attributes: WorkspaceInitActivityAttributes
    let state: WorkspaceInitActivityAttributes.ContentState

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(attributes.name)
                    .font(.headline)
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ProgressView(value: Double(state.completedSteps), total: Double(max(state.totalSteps, 1)))
                .frame(width: 60)
        }
        .padding()
    }

    private var statusText: String {
        if state.isSettled {
            return state.succeeded ? "初始化完成，可以开始问答" : "初始化失败，请在 App 内重试"
        }
        return state.currentStepName.isEmpty ? "初始化中…" : "正在\(state.currentStepName)…"
    }
}
#endif
