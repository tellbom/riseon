import SwiftUI
import UIKit

struct ChatView: View {
    let code: String
    let workspaceStore: WorkspaceStore

    @State private var workspace: StockWorkspace?
    @State private var question = ""
    @State private var isStreaming = false
    @State private var streamingText = ""
    @State private var errorMessage: String?
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var sendTask: Task<Void, Never>?

    private static let suggestedQuestions = [
        "现在这只股票的技术面怎么看？",
        "支撑和阻力在哪里？",
        "最近的趋势是涨还是跌？",
    ]

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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel("历史会话")
                .disabled(workspace == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    startNewThread()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("新建会话")
                .disabled(workspace == nil || isStreaming)
            }
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
        .sheet(isPresented: $showHistory) {
            if let workspace {
                ChatThreadListView(
                    workspace: Binding(
                        get: { self.workspace ?? workspace },
                        set: { self.workspace = $0 }
                    ),
                    workspaceStore: workspaceStore
                )
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
                qualityBadge(workspace.meta.quality)
            }
            if let snapshotDate = workspace.meta.snapshotDate {
                Text("数据快照：\(snapshotDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private func qualityBadge(_ quality: String?) -> some View {
        let (label, color) = qualityStyle(quality)
        return Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func qualityStyle(_ quality: String?) -> (String, Color) {
        switch quality {
        case "good": return ("数据良好", .green)
        case "usable": return ("数据可用", .blue)
        case "limited": return ("数据有限", .orange)
        case "poor": return ("数据较差", .red)
        default: return ("质量未知", .gray)
        }
    }

    private func messagesList(_ workspace: StockWorkspace) -> some View {
        let messages = workspace.activeChatThread?.messages ?? []
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty && !isStreaming {
                        emptyState
                    } else {
                        ForEach(messages.indices, id: \.self) { index in
                            MessageBubble(message: messages[index])
                                .id(index)
                        }
                        if isStreaming {
                            MessageBubble(message: ChatMessage(role: .assistant, content: streamingText))
                                .id("streaming")
                            if streamingText.isEmpty {
                                streamingIndicator
                            }
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
            .onChange(of: streamingText) {
                withAnimation(.easeOut(duration: 0.15)) {
                    if isStreaming {
                        proxy.scrollTo("streaming", anchor: .bottom)
                    } else if let lastIndex = messages.indices.last {
                        proxy.scrollTo(lastIndex, anchor: .bottom)
                    }
                }
            }
            .onChange(of: messages.count) {
                withAnimation(.easeOut(duration: 0.15)) {
                    if let lastIndex = messages.indices.last {
                        proxy.scrollTo(lastIndex, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var streamingIndicator: some View {
        HStack {
            ProgressView().controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "还没有对话",
                systemImage: "message",
                description: Text("试试下面这些问题，或者直接输入你自己的问题")
            )
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.suggestedQuestions, id: \.self) { suggestion in
                    Button {
                        question = suggestion
                    } label: {
                        Text(suggestion)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                            .foregroundStyle(.primary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 16)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("输入你的问题", text: $question, axis: .vertical)
                .lineLimit(1...4)
                .disabled(isStreaming)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: Capsule())

            Button {
                if isStreaming {
                    stopStreaming()
                } else {
                    sendQuestion()
                }
            } label: {
                Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Circle())
            .disabled(!isStreaming && question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(isStreaming ? "停止生成" : "发送问题")
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

    private func startNewThread() {
        guard var current = workspace else { return }
        current.startNewChatThread()
        workspace = current
        Task { try? await workspaceStore.save(current) }
    }

    private func sendQuestion() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, workspace != nil else { return }
        question = ""
        sendTask = Task { await runStream(question: trimmed) }
    }

    private func stopStreaming() {
        sendTask?.cancel()
    }

    private func runStream(question: String) async {
        guard var current = workspace else { return }
        isStreaming = true
        errorMessage = nil
        streamingText = ""

        do {
            let service = try LLMConfigurationStore.makeService()
            let stream = try WorkspaceChatService.streamAsk(question, in: &current, llmService: service)
            workspace = current
            try await workspaceStore.save(current)

            for try await delta in stream {
                if Task.isCancelled { break }
                streamingText += delta
            }

            if !streamingText.isEmpty {
                try WorkspaceChatService.finalizeStreamedAnswer(streamingText, in: &current)
                workspace = current
                try await workspaceStore.save(current)
            }
        } catch {
            if let serviceError = error as? LLMServiceError {
                errorMessage = serviceError.localizedDescription
            } else {
                errorMessage = error.localizedDescription
            }
        }

        streamingText = ""
        isStreaming = false
        sendTask = nil
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .assistant {
                ChatAvatar(role: message.role)
                VStack(alignment: .leading, spacing: 4) {
                    senderLabel
                    bubble
                    timestamp(alignment: .leading)
                }
                Spacer(minLength: 36)
            } else {
                Spacer(minLength: 36)
                VStack(alignment: .trailing, spacing: 4) {
                    senderLabel
                    bubble
                    timestamp(alignment: .trailing)
                }
                ChatAvatar(role: message.role)
            }
        }
    }

    private var bubble: some View {
        MarkdownText(content: message.content, isAssistant: message.role == .assistant)
            .padding(.horizontal, message.role == .assistant ? 14 : 13)
            .padding(.vertical, message.role == .assistant ? 12 : 10)
            .background(bubbleBackground)
            .clipShape(bubbleShape)
            .shadow(color: shadowColor, radius: message.role == .assistant ? 8 : 3, y: 2)
            .textSelection(.enabled)
            .contextMenu {
                Button {
                    UIPasteboard.general.string = message.content
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
            }
    }

    private var senderLabel: some View {
        Text(message.role == .assistant ? "RiseOn" : "你")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
    }

    private func timestamp(alignment: Alignment) -> some View {
        Text(message.createdAt.formatted(date: .omitted, time: .shortened))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: alignment)
            .padding(.horizontal, 2)
    }

    private var bubbleBackground: some ShapeStyle {
        if message.role == .assistant {
            AnyShapeStyle(.regularMaterial)
        } else {
            AnyShapeStyle(Color.accentColor.gradient)
        }
    }

    private var shadowColor: Color {
        message.role == .assistant ? Color.black.opacity(0.08) : Color.accentColor.opacity(0.18)
    }

    private var bubbleShape: some Shape {
        UnevenRoundedRectangle(
            topLeadingRadius: 16,
            bottomLeadingRadius: message.role == .assistant ? 4 : 16,
            bottomTrailingRadius: message.role == .assistant ? 16 : 4,
            topTrailingRadius: 16
        )
    }
}

private struct ChatAvatar: View {
    let role: ChatRole

    var body: some View {
        ZStack {
            Circle()
                .fill(background)
            Image(systemName: role == .assistant ? "sparkles" : "person.fill")
                .font(.system(size: role == .assistant ? 13 : 14, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 32, height: 32)
        .shadow(color: shadowColor, radius: 4, y: 2)
        .accessibilityHidden(true)
    }

    private var background: some ShapeStyle {
        if role == .assistant {
            AnyShapeStyle(LinearGradient(
                colors: [Color.blue, Color.teal],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        } else {
            AnyShapeStyle(LinearGradient(
                colors: [Color.gray.opacity(0.72), Color.gray.opacity(0.48)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        }
    }

    private var shadowColor: Color {
        role == .assistant ? Color.blue.opacity(0.18) : Color.black.opacity(0.08)
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
