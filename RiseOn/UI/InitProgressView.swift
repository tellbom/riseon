import SwiftUI

/// Step-by-step initialization progress screen (task.md S13.1, plan.md §4.4):
/// shows Steps A-E (Step F "就绪" is a terminal state, not itself a step —
/// see `InitStep`), each with its live status, and a retry button once the
/// pipeline has stopped on a failed step.
///
/// Reads through `InitProgressViewModel`, which polls `InitializationQueue`
/// for this one stock's `code` — this view itself does no queue access
/// directly, matching how `HomeListView` (S1) delegates to its own view
/// model rather than touching `WatchlistStore` inline.
struct InitProgressView: View {
    @StateObject private var viewModel: InitProgressViewModel

    init(code: String, queue: InitializationQueue) {
        _viewModel = StateObject(wrappedValue: InitProgressViewModel(code: code, queue: queue))
    }

    var body: some View {
        List {
            Section("初始化步骤") {
                ForEach(viewModel.tasks, id: \.step) { task in
                    InitStepRow(task: task)
                }
            }

            switch viewModel.outcome {
            case .succeeded:
                Section {
                    Label("初始化完成", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("初始化完成")
                }
            case .failed(let step):
                Section {
                    Label("在「\(InitStepRow.label(for: step))」这一步失败了", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Button {
                        Task { await viewModel.retry() }
                    } label: {
                        HStack {
                            if viewModel.isRetrying {
                                ProgressView()
                            }
                            Text(viewModel.isRetrying ? "重试中…" : "重试")
                        }
                    }
                    .disabled(viewModel.isRetrying)
                    .accessibilityLabel(viewModel.isRetrying ? "正在重试" : "重试这一步")
                }
            case nil:
                EmptyView()
            }
        }
        .navigationTitle("初始化进度")
        .task { await viewModel.observe() }
    }
}

private struct InitStepRow: View {
    let task: InitTask

    var body: some View {
        HStack {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.label(for: task.step))
                if task.retries > 0 {
                    Text("已重试 \(task.retries) 次")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Self.label(for: task.step))，\(statusAccessibilityLabel)")
    }

    private var iconName: String {
        switch task.status {
        case .pending: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch task.status {
        case .pending: return .secondary
        case .running: return .blue
        case .succeeded: return .green
        case .failed: return .red
        }
    }

    private var statusAccessibilityLabel: String {
        switch task.status {
        case .pending: return "等待中"
        case .running: return "进行中"
        case .succeeded: return "已完成"
        case .failed: return "失败"
        }
    }

    static func label(for step: InitStep) -> String {
        switch step {
        case .fetchDailyBars: return "拉取日线"
        case .overlayRealtime: return "叠加实时行情"
        case .computeIndicators: return "计算技术指标"
        case .computeRuleScore: return "计算规则评分"
        case .buildPack: return "打包上下文"
        }
    }
}

#Preview {
    NavigationStack {
        InitProgressView(
            code: "600519",
            queue: InitializationQueue { _, _ in
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        )
    }
}
