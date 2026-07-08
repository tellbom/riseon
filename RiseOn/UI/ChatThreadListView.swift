import SwiftUI

/// The "历史记录对话框" from the chat UI's toolbar: lists every independent
/// `ChatThread` for this stock (not just the one continuous session the app
/// used to keep), letting the user switch back to an older conversation,
/// start a fresh one, or delete one they don't need anymore.
struct ChatThreadListView: View {
    @Binding var workspace: StockWorkspace
    let workspaceStore: WorkspaceStore

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    private var sortedThreads: [ChatThread] {
        workspace.chatThreads.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sortedThreads) { thread in
                    Button {
                        select(thread)
                    } label: {
                        row(for: thread)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: delete)
            }
            .overlay {
                if sortedThreads.isEmpty {
                    ContentUnavailableView("还没有会话", systemImage: "clock.arrow.circlepath")
                }
            }
            .navigationTitle("历史会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        startNew()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("新建会话")
                }
            }
            .alert("操作失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func row(for thread: ChatThread) -> some View {
        let isActive = thread.id == workspace.activeChatThreadID
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color(.tertiarySystemFill)))
                    .frame(width: 38, height: 38)
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isActive ? .white : .secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title(for: thread))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(thread.updatedAt.formatted(date: .abbreviated, time: .shortened)) · \(thread.messages.count) 条消息")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isActive {
                Text("使用中")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func title(for thread: ChatThread) -> String {
        if let title = thread.title, !title.isEmpty {
            return title
        }
        if let firstQuestion = thread.messages.first(where: { $0.role == .user })?.content {
            return String(firstQuestion.prefix(20))
        }
        return "新会话"
    }

    private func select(_ thread: ChatThread) {
        do {
            try workspace.selectChatThread(id: thread.id)
            try persist()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startNew() {
        workspace.startNewChatThread()
        do {
            try persist()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(at offsets: IndexSet) {
        let threadsToDelete = offsets.map { sortedThreads[$0] }
        do {
            for thread in threadsToDelete {
                try workspace.deleteChatThread(id: thread.id)
            }
            try persist()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persist() throws {
        let snapshot = workspace
        Task { try? await workspaceStore.save(snapshot) }
    }
}

#Preview {
    struct PreviewHost: View {
        @State private var workspace = StockWorkspace(code: "600519", name: "贵州茅台", market: "SH")
        var body: some View {
            ChatThreadListView(
                workspace: $workspace,
                workspaceStore: try! WorkspaceStore(
                    directory: FileManager.default.temporaryDirectory.appendingPathComponent("preview-threads-\(UUID().uuidString)")
                )
            )
        }
    }
    return PreviewHost()
}
