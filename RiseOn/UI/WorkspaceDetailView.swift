import SwiftUI

struct WorkspaceDetailView: View {
    let code: String
    let workspaceStore: WorkspaceStore

    @State private var workspace: StockWorkspace?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let workspace {
                summarySection(workspace)

                if let score = workspace.ruleScore {
                    scoreSection(score)
                }

                Section {
                    NavigationLink {
                        ChatView(code: code, workspaceStore: workspaceStore)
                    } label: {
                        Label("进入问答", systemImage: "message")
                    }
                    .disabled(workspace.contextPack == nil)
                } footer: {
                    if workspace.contextPack == nil {
                        Text("还没有可用于问答的数据包，请先完成初始化。")
                    }
                }
            } else if let errorMessage {
                ContentUnavailableView("无法打开 Workspace", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                ProgressView("正在加载…")
            }
        }
        .navigationTitle(workspace?.name.isEmpty == false ? workspace?.name ?? code : code)
        .task { await loadWorkspace() }
        .refreshable { await loadWorkspace() }
    }

    private func summarySection(_ workspace: StockWorkspace) -> some View {
        Section("数据快照") {
            LabeledContent("代码", value: workspace.code)
            LabeledContent("市场", value: workspace.market)
            LabeledContent("状态", value: stateText(workspace.state))
            if let snapshotDate = workspace.meta.snapshotDate {
                LabeledContent("快照时间", value: snapshotDate.formatted(date: .abbreviated, time: .shortened))
            }
            if let quality = workspace.meta.quality {
                LabeledContent("质量", value: quality)
            }
        }
    }

    private func scoreSection(_ score: RuleScore) -> some View {
        Section("规则评分") {
            LabeledContent("分数", value: "\(score.signalScore)")
            LabeledContent("信号", value: score.buySignal.rawValue)
            LabeledContent("趋势", value: score.trendStatus.rawValue)
            LabeledContent("价格", value: String(format: "%.2f", score.currentPrice))
            if !score.supportLevels.isEmpty {
                LabeledContent("支撑位", value: score.supportLevels.map { String(format: "%.2f", $0) }.joined(separator: " / "))
            }
            if !score.resistanceLevels.isEmpty {
                LabeledContent("阻力位", value: score.resistanceLevels.map { String(format: "%.2f", $0) }.joined(separator: " / "))
            }
        }
    }

    private func loadWorkspace() async {
        do {
            workspace = try await workspaceStore.load(code: code)
            errorMessage = workspace == nil ? "未找到 \(code) 的 Workspace。" : nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stateText(_ state: WorkspaceState) -> String {
        switch state {
        case .uninitialized: return "未初始化"
        case .initializing: return "初始化中"
        case .ready: return "已就绪"
        case .stale: return "已过期"
        case .partial: return "部分就绪"
        case .failed(let step): return "失败：\(step.displayName)"
        }
    }
}

#Preview {
    NavigationStack {
        WorkspaceDetailView(
            code: "600519",
            workspaceStore: try! WorkspaceStore(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent("preview-detail-\(UUID().uuidString)")
            )
        )
    }
}
