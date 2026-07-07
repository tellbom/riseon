import ActivityKit
import SwiftUI
import WidgetKit

@main
@available(iOS 16.2, *)
struct WorkspaceInitActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkspaceInitActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(context.attributes.code)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.completedSteps)/\(context.state.totalSteps)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: Double(context.state.completedSteps), total: Double(max(context.state.totalSteps, 1)))
                        .tint(context.state.isSettled ? (context.state.succeeded ? .green : .red) : .blue)
                    Text(statusText(for: context.state))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: compactIconName(for: context.state))
                    .foregroundStyle(context.state.isSettled ? (context.state.succeeded ? .green : .red) : .blue)
            } compactTrailing: {
                Text("\(context.state.completedSteps)/\(context.state.totalSteps)")
                    .font(.caption2)
                    .monospacedDigit()
            } minimal: {
                Image(systemName: compactIconName(for: context.state))
                    .foregroundStyle(context.state.isSettled ? (context.state.succeeded ? .green : .red) : .blue)
            }
        }
    }

    private func compactIconName(for state: WorkspaceInitActivityAttributes.ContentState) -> String {
        guard state.isSettled else { return "arrow.triangle.2.circlepath" }
        return state.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private func statusText(for state: WorkspaceInitActivityAttributes.ContentState) -> String {
        if state.isSettled {
            return state.succeeded ? "初始化完成" : "初始化失败"
        }
        return state.currentStepName.isEmpty ? "初始化中" : state.currentStepName
    }
}

@available(iOS 16.2, *)
private struct LockScreenView: View {
    let attributes: WorkspaceInitActivityAttributes
    let state: WorkspaceInitActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(iconColor)
                .frame(width: 32, height: 32)
                .background(iconColor.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(attributes.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            ProgressView(value: Double(state.completedSteps), total: Double(max(state.totalSteps, 1)))
                .progressViewStyle(.circular)
                .tint(iconColor)
                .frame(width: 36, height: 36)
        }
        .padding()
    }

    private var iconName: String {
        guard state.isSettled else { return "arrow.triangle.2.circlepath" }
        return state.succeeded ? "checkmark" : "exclamationmark"
    }

    private var iconColor: Color {
        guard state.isSettled else { return .blue }
        return state.succeeded ? .green : .red
    }

    private var statusText: String {
        if state.isSettled {
            return state.succeeded ? "初始化完成，可以开始问答" : "初始化失败，请在 App 内重试"
        }
        return state.currentStepName.isEmpty ? "初始化中" : "正在\(state.currentStepName)"
    }
}
