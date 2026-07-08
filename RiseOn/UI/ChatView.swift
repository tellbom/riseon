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
    @FocusState private var composerFocused: Bool

    private static let suggestedQuestions: [(icon: String, text: String)] = [
        ("chart.line.uptrend.xyaxis", "现在这只股票的技术面怎么看？"),
        ("arrow.up.arrow.down", "支撑和阻力分别在哪里？"),
        ("scope", "给出结构化的买卖点参考"),
        ("shield.lefthalf.filled", "当前主要有哪些风险？"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            if let workspace {
                header(workspace)
                messagesList(workspace)
                composer
            } else if let errorMessage {
                ContentUnavailableView("无法进入问答", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                ProgressView("正在加载…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(.systemGroupedBackground))
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

    // MARK: - Header

    private func header(_ workspace: StockWorkspace) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(workspace.name.isEmpty ? workspace.code : workspace.name)
                            .font(.headline)
                            .lineLimit(1)
                        if !workspace.name.isEmpty {
                            Text(workspace.code)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let snapshotDate = workspace.meta.snapshotDate {
                        Label(
                            "数据快照 \(snapshotDate.formatted(date: .abbreviated, time: .shortened))",
                            systemImage: "clock"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                    }
                }
                Spacer(minLength: 8)
                qualityBadge(workspace.meta.quality)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)

            Divider().opacity(0.6)
        }
        .background(.ultraThinMaterial)
    }

    private func qualityBadge(_ quality: String?) -> some View {
        let (label, color) = qualityStyle(quality)
        return HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
        .foregroundStyle(color)
        .overlay(Capsule().stroke(color.opacity(0.22), lineWidth: 0.5))
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

    // MARK: - Messages

    private func messagesList(_ workspace: StockWorkspace) -> some View {
        let messages = workspace.activeChatThread?.messages ?? []
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if messages.isEmpty && !isStreaming {
                        emptyState(workspace)
                    } else {
                        ForEach(messages.indices, id: \.self) { index in
                            MessageBubble(message: messages[index])
                                .id(index)
                        }
                        if isStreaming {
                            if streamingText.isEmpty {
                                TypingBubble()
                                    .id("streaming")
                            } else {
                                MessageBubble(message: ChatMessage(role: .assistant, content: streamingText))
                                    .id("streaming")
                            }
                        }
                    }
                    if let errorMessage {
                        errorCard(errorMessage)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .scrollDismissesKeyboard(.interactively)
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

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.25), lineWidth: 0.5))
    }

    // MARK: - Empty state

    private func emptyState(_ workspace: StockWorkspace) -> some View {
        let name = workspace.name.isEmpty ? workspace.code : workspace.name
        return VStack(spacing: 22) {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.blue, .teal],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 60, height: 60)
                        .shadow(color: .blue.opacity(0.28), radius: 10, y: 4)
                    Image(systemName: "sparkles")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(spacing: 5) {
                    Text("和「\(name)」聊聊")
                        .font(.title3.weight(.semibold))
                    Text("基于端上的行情、指标与规则评分作答，不含实时新闻。选一个开始，或直接输入问题。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 28)

            VStack(spacing: 10) {
                ForEach(Self.suggestedQuestions, id: \.text) { suggestion in
                    suggestionCard(icon: suggestion.icon, text: suggestion.text)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
    }

    private func suggestionCard(icon: String, text: String) -> some View {
        Button {
            question = text
            composerFocused = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.left")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 13)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.05), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.6)
            HStack(alignment: .bottom, spacing: 10) {
                TextField("输入你的问题…", text: $question, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .disabled(isStreaming)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )

                sendButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private var sendButton: some View {
        let canSend = !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button {
            if isStreaming {
                stopStreaming()
            } else {
                sendQuestion()
            }
        } label: {
            Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(sendButtonBackground(canSend: canSend), in: Circle())
        }
        .disabled(!isStreaming && !canSend)
        .animation(.easeInOut(duration: 0.15), value: canSend)
        .animation(.easeInOut(duration: 0.15), value: isStreaming)
        .accessibilityLabel(isStreaming ? "停止生成" : "发送问题")
    }

    private func sendButtonBackground(canSend: Bool) -> AnyShapeStyle {
        if isStreaming {
            return AnyShapeStyle(Color.red.gradient)
        }
        if canSend {
            return AnyShapeStyle(Color.accentColor.gradient)
        }
        return AnyShapeStyle(Color(.systemGray3))
    }

    // MARK: - Logic (unchanged)

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

        let settings = LLMConfigurationStore.load()
        let options = PromptBuilder.Options(webSearchEnabled: settings.webSearchEnabled)

        do {
            let service = try LLMConfigurationStore.makeService(settings: settings)
            let usesToolRound = settings.webSearchEnabled
                && ((try? WebSearchAPIKeyStore.exists()) ?? false)

            if usesToolRound {
                // Web-search runs a tool round (search → feed back → answer),
                // which needs full round-trips rather than a token stream —
                // `ask` records both sides itself, so there's nothing to
                // finalize afterward.
                let answer = try await WorkspaceChatService.ask(question, in: &current, llmService: service, options: options)
                streamingText = answer
                workspace = current
                try await workspaceStore.save(current)
            } else {
                let stream = try WorkspaceChatService.streamAsk(question, in: &current, llmService: service, options: options)
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
            }
        } catch {
            // Persist whatever was recorded (e.g. the user's question `ask`/
            // `streamAsk` appended before failing) so it isn't lost on error.
            workspace = current
            try? await workspaceStore.save(current)
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

// MARK: - Message bubble

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
                Spacer(minLength: 32)
            } else {
                Spacer(minLength: 32)
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
            .overlay(
                bubbleShape
                    .stroke(Color.primary.opacity(message.role == .assistant ? 0.05 : 0), lineWidth: 0.5)
            )
            .shadow(color: shadowColor, radius: message.role == .assistant ? 5 : 4, y: 2)
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
            AnyShapeStyle(Color(.secondarySystemGroupedBackground))
        } else {
            AnyShapeStyle(Color.accentColor.gradient)
        }
    }

    private var shadowColor: Color {
        message.role == .assistant ? Color.black.opacity(0.06) : Color.accentColor.opacity(0.18)
    }

    private var bubbleShape: some Shape {
        UnevenRoundedRectangle(
            topLeadingRadius: 18,
            bottomLeadingRadius: message.role == .assistant ? 5 : 18,
            bottomTrailingRadius: message.role == .assistant ? 18 : 5,
            topTrailingRadius: 18
        )
    }
}

// MARK: - Typing indicator

private struct TypingBubble: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ChatAvatar(role: .assistant)
            VStack(alignment: .leading, spacing: 4) {
                Text("RiseOn")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
                TypingDots()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 18,
                            bottomLeadingRadius: 5,
                            bottomTrailingRadius: 18,
                            topTrailingRadius: 18
                        )
                        .fill(Color(.secondarySystemGroupedBackground))
                    )
                    .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
            }
            Spacer(minLength: 32)
        }
        .accessibilityLabel("正在生成回复")
    }
}

private struct TypingDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 7, height: 7)
                    .foregroundStyle(.secondary)
                    .opacity(animating ? 1 : 0.3)
                    .scaleEffect(animating ? 1 : 0.7)
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever()
                            .delay(Double(index) * 0.18),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

// MARK: - Avatar

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
    @State private var webSearchEnabled = LLMConfigurationStore.load().webSearchEnabled
    @State private var apiKey = ""
    @State private var searchApiKey = ""
    @State private var hasStoredKey = (try? LLMAPIKeyStore.exists()) ?? false
    @State private var hasStoredSearchKey = (try? WebSearchAPIKeyStore.exists()) ?? false
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section {
                ForEach(LLMConfigurationStore.presets) { preset in
                    Button {
                        applyPreset(preset)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: preset.webCapable ? "globe" : "cpu")
                                .foregroundStyle(preset.webCapable ? Color.blue : Color.secondary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                Text(preset.note).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if endpoint == preset.endpoint && model == preset.model {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("模型预设")
            } footer: {
                Text("带地球图标的模型自带联网检索，可补新闻/公告/舆情。")
            }

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

            Section {
                Toggle("允许模型联网检索新闻/舆情", isOn: $webSearchEnabled)
                if webSearchEnabled {
                    SecureField(hasStoredSearchKey ? "搜索 Key 已保存，留空则不修改" : "Tavily 搜索 API Key（可选）", text: $searchApiKey)
                        .textInputAutocapitalization(.never)
                    if hasStoredSearchKey {
                        Button(role: .destructive) {
                            deleteSearchKey()
                        } label: {
                            Label("删除搜索 Key", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("联网检索")
            } footer: {
                Text("开启后：若模型自带联网（如 Perplexity sonar），直接检索；否则可填 Tavily Key 走 web_search 工具检索。关闭时严格离线、不联网。")
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

    private func applyPreset(_ preset: LLMConfigurationStore.Preset) {
        endpoint = preset.endpoint
        model = preset.model
        if preset.webCapable {
            webSearchEnabled = true
        }
    }

    private func save() {
        let settings = LLMConfigurationStore.Settings(endpoint: endpoint, model: model, webSearchEnabled: webSearchEnabled)
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
            let trimmedSearchKey = searchApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSearchKey.isEmpty {
                try WebSearchAPIKeyStore.save(trimmedSearchKey)
                hasStoredSearchKey = true
                searchApiKey = ""
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

    private func deleteSearchKey() {
        do {
            try WebSearchAPIKeyStore.delete()
            hasStoredSearchKey = false
            statusMessage = "已删除搜索 Key。"
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
