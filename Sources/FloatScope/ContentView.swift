import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: FloatScopeModel
    @FocusState private var inputFocused: Bool
    @State private var shellWidth: CGFloat = 304
    @State private var containerWidth: CGFloat = 320
    @State private var widthAnimationToken = UUID()

    var body: some View {
        CapsuleBar(model: model, inputFocused: $inputFocused, shellWidth: shellWidth)
        .padding(8)
        .frame(width: containerWidth, alignment: .leading)
        .frame(height: FloatingPanelMetrics.collapsedHeight, alignment: .center)
        .sheet(isPresented: $model.showSettings) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $model.showHistory) {
            HistoryPickerView(model: model)
        }
        .sheet(isPresented: $model.showLongInputEditor) {
            LongInputEditorView(model: model)
        }
        .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: nil) { providers in
            model.addAttachmentProviders(providers)
        }
        .onChange(of: model.settings.capsuleOpacity) { _, newValue in
            NSApp.keyWindow?.alphaValue = newValue
        }
        .onChange(of: targetWidth) { _, width in
            updateWidths(to: width)
        }
        .onAppear {
            containerWidth = targetWidth
            shellWidth = targetWidth - 16
        }
    }

    private var targetWidth: CGFloat {
        if model.isExpanded {
            return 560
        }
        let textCount = model.inputText.count
        let attachmentWidth = CGFloat(min(model.pendingAttachments.count, 3) * 24)
        let width = 292 + CGFloat(min(textCount, 42)) * 6.2 + attachmentWidth
        return min(560, max(320, width))
    }

    private func updateWidths(to width: CGFloat) {
        let shellTarget = width - 16
        if width >= containerWidth {
            widthAnimationToken = UUID()
            containerWidth = width
            resizeFloatingWindow(width: width, animated: true)
            animateShellWidth(to: shellTarget)
        } else {
            let token = UUID()
            widthAnimationToken = token
            animateShellWidth(to: shellTarget)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                guard widthAnimationToken == token else { return }
                containerWidth = width
                resizeFloatingWindow(width: width, animated: false)
            }
        }
    }

    private func resizeFloatingWindow(width: CGFloat, animated: Bool) {
        guard let window = NSApp.windows.first(where: { $0 is FloatingPanel }) as? FloatingPanel else { return }
        let current = window.frame
        let resting = FloatingPanelMetrics.restingFrame(from: current)
        let target = NSRect(
            x: resting.minX,
            y: resting.minY,
            width: width,
            height: FloatingPanelMetrics.collapsedHeight
        )
        window.setAnchoredFrame(target, animated: animated)
        UserDefaults.standard.set(NSStringFromRect(resting), forKey: SettingsKeys.windowFrame)
    }

    private func animateShellWidth(to width: CGFloat) {
        let target = max(304, width)
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.88, blendDuration: 0.04)) {
            shellWidth = target
        }
    }
}

struct ConversationOverlayView: View {
    @ObservedObject var model: FloatScopeModel

    var body: some View {
        ConversationPanel(model: model)
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CapsuleBar: View {
    @ObservedObject var model: FloatScopeModel
    var inputFocused: FocusState<Bool>.Binding
    let shellWidth: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.regularMaterial)
                .frame(width: shellWidth)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                        .frame(width: shellWidth)
                }

            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Button {
                        model.addAttachments()
                    } label: {
                        Image(systemName: model.pendingAttachments.isEmpty ? "plus" : "plus.circle.fill")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("添加图像或文件")

                    AgentPickerMenu(model: model, mood: activeMood)

                    if !model.pendingAttachments.isEmpty {
                        AttachmentStrip(model: model)
                    }

                    if model.needsLongInputEditor {
                        Button {
                            model.openLongInputEditor()
                        } label: {
                            Text(draftPreview)
                                .font(.system(size: 13))
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(minWidth: 80)
                        .help("编辑长文本")
                    } else {
                        TextField("", text: $model.inputText)
                            .textFieldStyle(.plain)
                            .focused(inputFocused)
                            .frame(minWidth: 80)
                            .onSubmit {
                                model.sendCurrentInput()
                            }
                            .onChange(of: inputFocused.wrappedValue) { _, focused in
                                if focused { model.expand() }
                            }
                            .onChange(of: model.inputText) { _, _ in
                                if model.needsLongInputEditor {
                                    model.openLongInputEditor()
                                }
                            }
                    }

                    Button {
                        model.sendCurrentInput()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("发送")
                }
                .frame(height: 26)

                HStack(spacing: 18) {
                    ModelPickerMenu(model: model)

                    IconButton(systemName: "clock.arrow.circlepath", help: "聊天记录") {
                        model.openHistoryPicker()
                    }

                    IconButton(
                        systemName: model.isExpanded ? "chevron.down.circle" : "chevron.up.circle",
                        help: model.isExpanded ? "收回对话" : "展开对话"
                    ) {
                        model.toggleExpanded()
                    }

                    IconButton(systemName: model.watchMode == nil ? "eye" : "eye.fill", help: "看屏幕") {
                        model.manualScreenCapture()
                    }
                }
                .frame(height: 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .frame(width: shellWidth, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .compositingGroup()
        .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: nil) { providers in
            model.addAttachmentProviders(providers)
        }
    }

    private var activeMood: AgentMoodState {
        if model.selectedAgentID == "auto" {
            return model.moods.values.first(where: { $0 != .idle }) ?? .idle
        }
        return model.moods[model.selectedAgentID] ?? .idle
    }

    private var draftPreview: String {
        let flattened = model.inputText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.isEmpty ? "Draft" : flattened
    }
}

private struct AgentPickerMenu: View {
    @ObservedObject var model: FloatScopeModel
    let mood: AgentMoodState
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActiveMood)) { context in
                agentSymbol(pulse: pulseAmount(at: context.date))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .frame(width: 22, height: 22)
        .help("选择人格")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    model.selectedAgentID = "auto"
                    UserDefaults.standard.set("auto", forKey: SettingsKeys.selectedAgentID)
                    isPresented = false
                } label: {
                    HStack(spacing: 8) {
                        autoDots
                        Text("Auto")
                        Spacer()
                        if model.selectedAgentID == "auto" {
                            Image(systemName: "checkmark")
                        }
                    }
                    .frame(width: 170, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                ForEach(model.agentConfigs) { agent in
                    Button {
                        model.selectedAgentID = agent.id
                        UserDefaults.standard.set(agent.id, forKey: SettingsKeys.selectedAgentID)
                        isPresented = false
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(Color(hex: agent.color)).frame(width: 10, height: 10)
                            Text(agent.displayName)
                            Spacer()
                            if agent.id == model.selectedAgentID {
                                Image(systemName: "checkmark")
                            }
                        }
                        .frame(width: 170, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func agentSymbol(pulse: Double) -> some View {
        if model.selectedAgentID == "auto" {
            autoDots
                .scaleEffect(pulseScale(pulse))
                .opacity(pulseOpacity(pulse))
                .shadow(color: moodGlowColor, radius: pulseGlow(pulse))
        } else {
            Circle()
                .fill(Color(hex: model.agentConfigs.first(where: { $0.id == model.selectedAgentID })?.color ?? "#8E8E93"))
                .frame(width: 14, height: 14)
                .scaleEffect(pulseScale(pulse))
                .opacity(pulseOpacity(pulse))
                .shadow(color: moodGlowColor, radius: pulseGlow(pulse))
                .overlay {
                    Circle().stroke(.white.opacity(0.32), lineWidth: 0.8)
                }
        }
    }

    @ViewBuilder
    private var autoDots: some View {
        HStack(spacing: 2) {
            ForEach(model.agentConfigs.prefix(3)) { agent in
                Circle().fill(Color(hex: agent.color)).frame(width: 8, height: 8)
            }
        }
    }

    private var isActiveMood: Bool {
        mood == .thinking || mood == .speaking || mood == .watching
    }

    private func pulseAmount(at date: Date) -> Double {
        guard isActiveMood else { return 0 }
        let speed: Double = mood == .speaking ? 1.8 : 1.1
        return (sin(date.timeIntervalSinceReferenceDate * .pi * 2 * speed) + 1) / 2
    }

    private func pulseScale(_ pulse: Double) -> CGFloat {
        1 + CGFloat(pulse) * 0.2
    }

    private func pulseOpacity(_ pulse: Double) -> CGFloat {
        1 - CGFloat(pulse) * 0.24
    }

    private func pulseGlow(_ pulse: Double) -> CGFloat {
        switch mood {
        case .idle:
            0
        case .thinking:
            3 + CGFloat(pulse) * 5
        case .speaking:
            2 + CGFloat(pulse) * 4
        case .watching:
            2 + CGFloat(pulse) * 5
        case .error:
            5
        }
    }

    private var moodGlowColor: Color {
        switch mood {
        case .idle:
            .clear
        case .error:
            .red.opacity(0.75)
        default:
            mood.color.opacity(0.65)
        }
    }
}

private struct AttachmentStrip: View {
    @ObservedObject var model: FloatScopeModel

    var body: some View {
        HStack(spacing: 5) {
            ForEach(model.pendingAttachments.prefix(3), id: \.self) { url in
                Button {
                    model.removeAttachment(url)
                } label: {
                    Image(systemName: icon(for: url))
                        .font(.caption)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(url.lastPathComponent)
            }
        }
    }

    private func icon(for url: URL) -> String {
        let images: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "gif", "tiff", "bmp"]
        return images.contains(url.pathExtension.lowercased()) ? "photo" : "doc"
    }
}

private struct ConversationPanel: View {
    @ObservedObject var model: FloatScopeModel
    private let bottomID = "FloatScopeConversationBottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isLoadingHistory {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
            }

            if model.watchMode != nil {
                HStack {
                    Image(systemName: "eye.fill")
                        .font(.caption)
                        .foregroundStyle(.cyan)
                    Spacer()
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.messages.suffix(24)) { message in
                            MessageBubble(message: message, visuals: model.settings.visuals, agents: model.agentConfigs)
                                .id(message.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                    }
                }
                .frame(maxHeight: .infinity)
                .onAppear {
                    scrollToBottom(proxy, animated: false)
                }
                .onChange(of: model.messages.count) { _, _ in
                    scrollToBottom(proxy, animated: true)
                }
                .onChange(of: model.messages.last?.text ?? "") { _, _ in
                    scrollToBottom(proxy, animated: true)
                }
                .onChange(of: model.isLoadingHistory) { _, loading in
                    if !loading {
                        scrollToBottom(proxy, animated: false)
                    }
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let visuals: AgentVisualConfig
    let agents: [AgentRuntimeConfig]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }

            ForEach(message.attachments) { attachment in
                AttachmentPreview(attachment: attachment)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var background: Color {
        switch message.role {
        case .user:
            visuals.userColor.opacity(0.22)
        case .system:
            visuals.systemColor.opacity(0.15)
        case .agent(let agent):
            Color(hex: agents.first(where: { $0.id == agent })?.color ?? "#8E8E93").opacity(0.22)
        }
    }
}

private struct AttachmentPreview: View {
    let attachment: ChatAttachment

    var body: some View {
        if attachment.isImage, let image = NSImage(contentsOf: attachment.url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 220, maxHeight: 150, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                }
        } else {
            Label(attachment.filename, systemImage: "doc")
                .font(.caption)
                .lineLimit(1)
        }
    }
}

private struct StatusDot: View {
    let mood: AgentMoodState

    var body: some View {
        Circle()
            .fill(mood.color)
            .frame(width: 9, height: 9)
            .shadow(color: mood.color.opacity(0.7), radius: mood == .idle ? 0 : 5)
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.3), lineWidth: 1)
            }
            .help(mood.label)
    }
}

private struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct ModelPickerMenu: View {
    @ObservedObject var model: FloatScopeModel
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "sparkles")
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .frame(width: 22, height: 22)
        .help("选择当前人格使用的模型")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if model.selectedAgentID == model.agentConfigs.first?.id {
                    codexSection
                } else if model.selectedAgentID == model.agentConfigs.dropFirst().first?.id {
                    agent2Sections
                } else if model.selectedAgentID == "auto" {
                    ForEach(model.agentConfigs.prefix(2)) { agent in
                        Text(agent.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                        if agent.id == model.agentConfigs.first?.id {
                            codexSection
                        } else {
                            agent2Sections
                        }
                    }
                } else if let agent = model.agentConfigs.first(where: { $0.id == model.selectedAgentID }) {
                    Text(agent.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                    Text(agent.model ?? "Configured in Settings")
                        .font(.caption)
                        .padding(.horizontal, 10)
                    Text(agent.effort ?? agent.variant ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                } else {
                    Text("Configured in Settings")
                        .padding(.horizontal, 10)
                }
            }
            .padding(.vertical, 10)
            .frame(width: 260)
        }
    }

    @ViewBuilder
    private var codexSection: some View {
        ForEach(CodexModelPreset.allCases) { preset in
            Button {
                model.setCodexModelPreset(preset)
            } label: {
                modelRow(title: preset.displayName, selected: preset == model.codexModelPreset)
            }
            .buttonStyle(.plain)
        }
        Divider().padding(.vertical, 2)
        Text("Effort")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
        ForEach(ReasoningEffortPreset.allCases) { preset in
            Button {
                model.setCodexEffortPreset(preset)
                isPresented = false
            } label: {
                modelRow(title: preset.displayName, selected: preset == model.codexEffortPreset)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var agent2Sections: some View {
        Text("OpenCode Zen")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
        ForEach(OpenCodeModelPreset.opencodeZenCases) { preset in
            Button {
                model.setAgent2ModelPreset(preset)
                isPresented = false
            } label: {
                modelRow(title: preset.displayName, selected: preset == model.agent2ModelPreset)
            }
            .buttonStyle(.plain)
        }
        Divider().padding(.vertical, 2)
        Text("Google")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
        ForEach(OpenCodeModelPreset.googleCases) { preset in
            Button {
                model.setAgent2ModelPreset(preset)
            } label: {
                modelRow(title: preset.displayName, selected: preset == model.agent2ModelPreset)
            }
            .buttonStyle(.plain)
        }
        Divider().padding(.vertical, 2)
        Text("OpenRouter")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
        ForEach(OpenCodeModelPreset.openRouterCases) { preset in
            Button {
                model.setAgent2ModelPreset(preset)
            } label: {
                modelRow(title: preset.displayName, selected: preset == model.agent2ModelPreset)
            }
            .buttonStyle(.plain)
        }
        Divider().padding(.vertical, 2)
        Text("Variant")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
        ForEach(OpenCodeVariantPreset.allCases) { preset in
            Button {
                model.setAgent2VariantPreset(preset)
                isPresented = false
            } label: {
                modelRow(title: preset.displayName, selected: preset == model.agent2VariantPreset)
            }
            .buttonStyle(.plain)
        }
    }

    private func modelRow(title: String, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer()
            if selected {
                Image(systemName: "checkmark")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HistoryPickerView: View {
    @ObservedObject var model: FloatScopeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Conversation History")
                    .font(.headline)
                Spacer()
                Button {
                    model.refreshHistory()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }

            if model.historyEntries.isEmpty {
                if model.isLoadingHistory {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("No History", systemImage: "clock", description: Text("No FloatScope project conversations were found."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.historyEntries) { entry in
                            Button {
                                model.selectHistory(entry)
                            } label: {
                                HistoryRow(entry: entry, agents: model.agentConfigs)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            HStack {
                Spacer()
                Button("Close") {
                    model.showHistory = false
                }
            }
        }
        .padding(18)
        .frame(width: 460, height: 520)
        .onAppear {
            model.refreshHistory()
        }
    }
}

private struct HistoryRow: View {
    let entry: ConversationHistoryEntry
    let agents: [AgentRuntimeConfig]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 4) {
                if entry.codexThreadID != nil {
                    Circle().fill(Color(hex: agents.first?.color ?? "#FF6FB7")).frame(width: 9, height: 9)
                }
                if entry.opencodeSessionID != nil {
                    Circle().fill(Color(hex: agents.dropFirst().first?.color ?? "#A85BFF")).frame(width: 9, height: 9)
                }
            }
            .frame(width: 14)
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(shortDate(entry.updatedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !entry.preview.isEmpty {
                    Text(entry.preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("\(entry.messageCount) Messages")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

private struct LongInputEditorView: View {
    @ObservedObject var model: FloatScopeModel
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    model.showLongInputEditor = false
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("收起编辑器")

                Spacer()

                Text("\(model.inputText.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    model.sendCurrentInput()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .help("发送")
                .disabled(model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.pendingAttachments.isEmpty)
            }

            AppKitTextEditor(text: $model.inputText)
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                }
        }
        .padding(18)
        .frame(width: 640, height: 430)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onAppear {
            editorFocused = true
        }
    }
}

private struct AppKitTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: 18)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: FloatScopeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("FloatScope Settings")
                    .font(.headline)

                GroupBox("Agents") {
                    VStack(alignment: .leading, spacing: 12) {
                        colorField("User Color", color: model.settings.visuals.userColor, text: Binding(
                            get: { model.settings.userColorHex },
                            set: { model.settings.userColorHex = $0 }
                        ))

                        ForEach(Array(model.agentConfigs.enumerated()), id: \.element.id) { index, agent in
                            AgentConfigCard(
                                title: "Agent \(index + 1)",
                                config: binding(for: agent.id),
                                canRemove: model.agentConfigs.count > 1,
                                onRemove: {
                                    model.removeAgentConfig(id: agent.id)
                                }
                            )
                        }

                        Button {
                            model.addAgentConfig()
                        } label: {
                            Label("Add Agent", systemImage: "plus.circle")
                        }
                    }
                    .padding(.vertical, 4)
                }

                Picker("Agent 1 Model", selection: $model.codexModelPreset) {
                    ForEach(CodexModelPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .onChange(of: model.codexModelPreset) { _, value in
                    model.setCodexModelPreset(value)
                }

                Picker("Agent 1 Effort", selection: $model.codexEffortPreset) {
                    ForEach(ReasoningEffortPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .onChange(of: model.codexEffortPreset) { _, value in
                    model.setCodexEffortPreset(value)
                }

                Picker("Agent 2 Model", selection: $model.agent2ModelPreset) {
                    Section("OpenCode Zen") {
                        ForEach(OpenCodeModelPreset.opencodeZenCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    Section("Google") {
                        ForEach(OpenCodeModelPreset.googleCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    Section("OpenRouter") {
                        ForEach(OpenCodeModelPreset.openRouterCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                }
                .onChange(of: model.agent2ModelPreset) { _, value in
                    model.setAgent2ModelPreset(value)
                }

                Picker("Agent 2 Variant", selection: $model.agent2VariantPreset) {
                    ForEach(OpenCodeVariantPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .onChange(of: model.agent2VariantPreset) { _, value in
                    model.setAgent2VariantPreset(value)
                }

                settingsTextField("Conversation Project", text: Binding(
                    get: { model.settings.conversationRoot },
                    set: { model.settings.conversationRoot = $0 }
                ))

                Toggle("Launch at Login", isOn: Binding(
                    get: { model.settings.launchAtLogin },
                    set: { model.settings.launchAtLogin = $0 }
                ))

                Toggle("Show System Messages", isOn: Binding(
                    get: { model.settings.showSystemMessages },
                    set: { model.settings.showSystemMessages = $0 }
                ))

                HStack {
                    Text("Opacity")
                    Slider(value: Binding(
                        get: { Double(model.settings.capsuleOpacity) },
                        set: { model.settings.capsuleOpacity = CGFloat($0) }
                    ), in: 0.65...1)
                }

                HStack {
                    Text("Watch Interval")
                    TextField("60", value: Binding(
                        get: { model.settings.watchDefaultInterval },
                        set: { model.settings.watchDefaultInterval = $0 }
                    ), format: .number)
                    .frame(width: 80)
                    Text("Seconds")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Button("Cancel") {
                        model.showSettings = false
                    }
                    Button("Apply") {
                        model.applySettings()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
        }
        .background(.regularMaterial)
        .frame(width: 640, height: 720)
    }

    private func settingsTextField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
                .frame(width: 138, alignment: .leading)
            TextField(title, text: text)
        }
    }

    private func colorField(_ title: String, color: Color, text: Binding<String>) -> some View {
        HStack {
            Text(title)
                .frame(width: 138, alignment: .leading)
            Circle()
                .fill(color)
                .frame(width: 14, height: 14)
            TextField("#RRGGBB", text: text)
        }
    }

    private func binding(for id: String) -> Binding<AgentRuntimeConfig> {
        Binding(
            get: {
                model.agentConfigs.first(where: { $0.id == id }) ?? AgentHubConfigStore.makeAgent(index: model.agentConfigs.count + 1)
            },
            set: { updated in
                guard let index = model.agentConfigs.firstIndex(where: { $0.id == id }) else { return }
                model.agentConfigs[index] = updated
            }
        )
    }
}

private struct AgentConfigCard: View {
    let title: String
    @Binding var config: AgentRuntimeConfig
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if canRemove {
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Remove Agent")
                }
            }

            row("ID") {
                TextField("agent-id", text: $config.id)
            }
            row("Name") {
                TextField("Agent Name", text: $config.displayName)
            }
            row("Kind") {
                Picker("", selection: $config.kind) {
                    Text("Codex App Server").tag("codex-app-server")
                    Text("OpenCode Run").tag("opencode-run")
                    Text("Generic CLI").tag("generic-cli")
                    Text("Claude Code").tag("claude-code")
                    Text("OpenClaw").tag("openclaw")
                }
                .labelsHidden()
            }
            row("Color") {
                HStack {
                    Circle()
                        .fill(Color(hex: config.color))
                        .frame(width: 14, height: 14)
                    TextField("#RRGGBB", text: $config.color)
                }
            }
            row("Executable") {
                TextField("/path/to/cli", text: $config.executablePath)
            }
            row("Model") {
                if let models = config.models, !models.isEmpty {
                    Picker("", selection: Binding(
                        get: { config.model ?? models.first ?? "" },
                        set: { config.model = $0.isEmpty ? nil : $0 }
                    )) {
                        ForEach(models, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                } else {
                    TextField("provider/model", text: Binding(
                        get: { config.model ?? "" },
                        set: { config.model = $0.isEmpty ? nil : $0 }
                    ))
                }
            }
            row("Effort") {
                let options = config.kind == "opencode-run" ? (config.variants ?? []) : (config.efforts ?? [])
                if !options.isEmpty {
                    Picker("", selection: Binding(
                        get: { config.kind == "opencode-run" ? (config.variant ?? options.first ?? "") : (config.effort ?? options.first ?? "") },
                        set: {
                            if config.kind == "opencode-run" {
                                config.variant = $0.isEmpty ? nil : $0
                            } else {
                                config.effort = $0.isEmpty ? nil : $0
                            }
                        }
                    )) {
                        ForEach(options, id: \.self) { option in
                            Text(effortLabel(option)).tag(option)
                        }
                    }
                    .labelsHidden()
                } else {
                    TextField("low / medium / high / xhigh", text: Binding(
                        get: { config.effort ?? config.variant ?? "" },
                        set: {
                            if config.kind == "opencode-run" {
                                config.variant = $0.isEmpty ? nil : $0
                            } else {
                                config.effort = $0.isEmpty ? nil : $0
                            }
                        }
                    ))
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
                .frame(width: 82, alignment: .leading)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func effortLabel(_ value: String) -> String {
        switch value.lowercased() {
        case "xhigh": "XHigh"
        case "auto", "automatic": "Auto"
        default: value.capitalized
        }
    }
}
