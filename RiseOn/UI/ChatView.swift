import SwiftUI

struct ChatView: View {
    let code: String
    let workspaceStore: WorkspaceStore

    @State private var workspace: StockWorkspace?
    @State private var question = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            if let workspace {
                header(workspace)
                Divider()
                messagesList(workspace)
                composer
            } else if let errorMessage {
                ContentUnavailableView("无法进入问答", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                ProgressView("正在加载…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("个股问答")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("配置 LLM")
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                LLMSettingsView()
            }
        }
        .task { await loadWorkspace() }
    }

    private func header(_ workspace: StockWorkspace) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(workspace.name.isEmpty ? workspace.code : workspace.name)
                    .font(.headline)
                Spacer()
                Text(workspace.meta.quality ?? "unknown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let snapshotDate = workspace.meta.snapshotDate {
                Text("数据快照：\(snapshotDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func messagesList(_ workspace: StockWorkspace) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if workspace.chatSession.messages.isEmpty {
                    ContentUnavailableView(
                        "还没有对话",
                        systemImage: "message",
                        description: Text("可以问：现在这只股票的技术面怎么看？支撑和阻力在哪里？")
                    )
                    .padding(.top, 32)
                } else {
                    ForEach(workspace.chatSession.messages.indices, id: \.self) { index in
                        MessageBubble(message: workspace.chatSession.messages[index])
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("输入你的问题", text: $question, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(isSending)

            Button {
                Task { await sendQuestion() }
            } label: {
                if isSending {
                    ProgressView()
                } else {
                    Image(systemName: "paperplane.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSending || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("发送问题")
        }
        .padding()
        .background(.bar)
    }

    private func loadWorkspace() async {
        do {
            workspace = try await workspaceStore.load(code: code)
            errorMessage = workspace == nil ? "未找到 \(code) 的 Workspace。" : nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sendQuestion() async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var current = workspace else { return }

        isSending = true
        errorMessage = nil
        question = ""

        do {
            let service = try LLMConfigurationStore.makeService()
            _ = try await WorkspaceChatService.ask(trimmed, in: &current, llmService: service)
            try await workspaceStore.save(current)
            workspace = current
        } catch {
            if let serviceError = error as? LLMServiceError {
                errorMessage = serviceError.localizedDescription
            } else {
                errorMessage = error.localizedDescription
            }
            if current.chatSession.messages.last?.role == .user {
                try? await workspaceStore.save(current)
                workspace = current
            }
        }
        isSending = false
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .assistant {
                bubble.foregroundStyle(.primary)
                Spacer(minLength: 32)
            } else {
                Spacer(minLength: 32)
                bubble.foregroundStyle(.white)
            }
        }
    }

    private var bubble: some View {
        Text(message.content)
            .font(.body)
            .padding(10)
            .background(message.role == .assistant ? Color(.secondarySystemBackground) : Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .textSelection(.enabled)
    }
}

private struct LLMSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var endpoint = LLMConfigurationStore.load().endpoint
    @State private var model = LLMConfigurationStore.load().model
    @State private var apiKey = ""
    @State private var hasStoredKey = (try? LLMAPIKeyStore.exists()) ?? false
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section("OpenAI 兼容接口") {
                TextField("Endpoint", text: $endpoint)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                TextField("Model", text: $model)
                    .textInputAutocapitalization(.never)
            }

            Section("API Key") {
                SecureField(hasStoredKey ? "已保存，留空则不修改" : "请输入 API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                if hasStoredKey {
                    Button(role: .destructive) {
                        deleteKey()
                    } label: {
                        Label("删除已保存 Key", systemImage: "trash")
                    }
                }
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("LLM 设置")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
            }
        }
    }

    private func save() {
        let settings = LLMConfigurationStore.Settings(endpoint: endpoint, model: model)
        guard settings.isUsable else {
            statusMessage = "请填写有效的 endpoint 和 model。"
            return
        }

        do {
            LLMConfigurationStore.save(settings)
            let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty {
                try LLMAPIKeyStore.save(trimmedKey)
                hasStoredKey = true
                apiKey = ""
            }
            statusMessage = "已保存。"
            dismiss()
        } catch {
            statusMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func deleteKey() {
        do {
            try LLMAPIKeyStore.delete()
            hasStoredKey = false
            statusMessage = "已删除 API Key。"
        } catch {
            statusMessage = "删除失败：\(error.localizedDescription)"
        }
    }
}

#Preview {
    NavigationStack {
        ChatView(
            code: "600519",
            workspaceStore: try! WorkspaceStore(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent("preview-chat-\(UUID().uuidString)")
            )
        )
    }
}
