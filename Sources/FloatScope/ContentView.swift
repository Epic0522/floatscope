import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct FrostedGlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = true
    }
}

private struct GlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    var material: NSVisualEffectView.Material = .hudWindow
    var strokeOpacity: Double = 0.18

    func body(content: Content) -> some View {
        content
            .background {
                FrostedGlassBackground(material: material)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(strokeOpacity), lineWidth: 1)
            }
    }
}

private extension View {
    func glassSurface(cornerRadius: CGFloat, material: NSVisualEffectView.Material = .hudWindow, strokeOpacity: Double = 0.18) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, material: material, strokeOpacity: strokeOpacity))
    }
}

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
                .frame(width: shellWidth)
                .overlay {
                    FrostedGlassBackground(material: .hudWindow)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.2), lineWidth: 1)
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
                    .help(L10n.text(.addAttachment, language: model.settings.appLanguage))

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
                        .help(L10n.text(.editLongText, language: model.settings.appLanguage))
                    } else {
                        AppKitSingleLineInput(
                            text: $model.inputText,
                            isFocused: inputFocused,
                            onSubmit: {
                                model.sendCurrentInput()
                            },
                            onShiftEnter: {
                                if !model.inputText.hasSuffix("\n") {
                                    model.inputText += "\n"
                                }
                                model.openLongInputEditor()
                            }
                        )
                            .frame(minWidth: 80)
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
                    .help(L10n.text(.send, language: model.settings.appLanguage))
                }
                .frame(height: 26)

                HStack(spacing: 18) {
                    ModelPickerMenu(model: model)

                    IconButton(systemName: "clock.arrow.circlepath", help: L10n.text(.history, language: model.settings.appLanguage)) {
                        model.openHistoryPicker()
                    }

                    IconButton(
                        systemName: model.isExpanded ? "chevron.down.circle" : "chevron.up.circle",
                        help: model.isExpanded ? L10n.text(.collapse, language: model.settings.appLanguage) : L10n.text(.expand, language: model.settings.appLanguage)
                    ) {
                        model.toggleExpanded()
                    }

                    IconButton(systemName: model.watchMode == nil ? "camera" : "camera.fill", help: L10n.text(.screenCapture, language: model.settings.appLanguage)) {
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
        if isGroupSelected {
            if !model.pendingResponseAgents.isEmpty {
                let pendingMoods = model.pendingResponseAgents.map { model.moods[$0] ?? .thinking }
                if pendingMoods.contains(.speaking) { return .speaking }
                if pendingMoods.contains(.watching) { return .watching }
                return .thinking
            }
            return model.moods.values.first(where: { $0 != .idle }) ?? .idle
        }
        let mood = model.moods[model.selectedAgentID] ?? .idle
        if model.pendingResponseAgents.contains(model.selectedAgentID), mood == .idle {
            return .thinking
        }
        return mood
    }

    private var isGroupSelected: Bool {
        model.selectedAgentID == "group" || model.selectedAgentID == "auto"
    }

    private var draftPreview: String {
        let flattened = model.inputText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.isEmpty ? L10n.text(.draft, language: model.settings.appLanguage) : flattened
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
        .help(L10n.text(.agentPickerHelp, language: model.settings.appLanguage))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    model.selectedAgentID = "group"
                    UserDefaults.standard.set("group", forKey: SettingsKeys.selectedAgentID)
                    isPresented = false
                } label: {
                    HStack(spacing: 8) {
                        autoDots
                        Text(L10n.text(.group, language: model.settings.appLanguage))
                        Spacer()
                        if isGroupSelected {
                            Image(systemName: "checkmark")
                        }
                    }
                    .frame(width: 170, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                ForEach(model.agentConfigs) { agent in
                    VStack(alignment: .leading, spacing: 4) {
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

                        if agent.id == model.agentConfigs.first?.id {
                            codexLaunchModeControls(currentKind: agent.kind)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func agentSymbol(pulse: Double) -> some View {
        if isGroupSelected {
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

    private var isGroupSelected: Bool {
        model.selectedAgentID == "group" || model.selectedAgentID == "auto"
    }

    private func codexLaunchModeControls(currentKind: String) -> some View {
        HStack(spacing: 6) {
            modeButton(title: "App", kind: "codex-app-server", currentKind: currentKind)
            modeButton(title: "CLI", kind: "codex-cli-resume", currentKind: currentKind)
        }
        .padding(.leading, 18)
    }

    private func modeButton(title: String, kind: String, currentKind: String) -> some View {
        Button {
            model.setCodexLaunchMode(kind)
            isPresented = false
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background {
                    Capsule()
                        .fill(currentKind == kind ? Color.primary.opacity(0.18) : Color.primary.opacity(0.06))
                }
        }
        .buttonStyle(.plain)
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

private struct AppKitSingleLineInput: NSViewRepresentable {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var onSubmit: () -> Void
    var onShiftEnter: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: isFocused, onSubmit: onSubmit, onShiftEnter: onShiftEnter)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = SingleLineTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.onShiftEnter = onShiftEnter
        textView.string = text
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.minSize = NSSize(width: 0, height: 22)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 22)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 22)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = true
        textView.autoresizingMask = [.height]

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SingleLineTextView else { return }
        if textView.string != text {
            textView.string = text
            textView.selectedRange = NSRange(location: text.utf16.count, length: 0)
        }
        textView.onSubmit = onSubmit
        textView.onShiftEnter = onShiftEnter
        context.coordinator.text = $text
        context.coordinator.isFocused = isFocused
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onShiftEnter = onShiftEnter
        context.coordinator.textView = textView

        if isFocused.wrappedValue, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                textView.selectedRange = NSRange(location: textView.string.utf16.count, length: 0)
                textView.keepInsertionPointVisible()
            }
        } else {
            DispatchQueue.main.async {
                textView.keepInsertionPointVisible()
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var isFocused: FocusState<Bool>.Binding
        var onSubmit: () -> Void
        var onShiftEnter: () -> Void
        weak var textView: SingleLineTextView?

        init(text: Binding<String>, isFocused: FocusState<Bool>.Binding, onSubmit: @escaping () -> Void, onShiftEnter: @escaping () -> Void) {
            self.text = text
            self.isFocused = isFocused
            self.onSubmit = onSubmit
            self.onShiftEnter = onShiftEnter
        }

        func textDidBeginEditing(_ notification: Notification) {
            isFocused.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isFocused.wrappedValue = false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? SingleLineTextView else { return }
            if textView.hasMarkedText() {
                textView.keepInsertionPointVisible()
                return
            }
            text.wrappedValue = textView.singleLineString
            textView.keepInsertionPointVisible()
        }
    }

    final class SingleLineTextView: NSTextView {
        var onSubmit: (() -> Void)?
        var onShiftEnter: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            if !hasMarkedText(),
               let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
               scalar.value == 13 || scalar.value == 3 {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags == .shift {
                    onShiftEnter?()
                    return
                }
                if flags.isEmpty {
                    onSubmit?()
                    return
                }
            }
            super.keyDown(with: event)
            keepInsertionPointVisible()
        }

        override func paste(_ sender: Any?) {
            super.paste(sender)
            string = singleLineString
            selectedRange = NSRange(location: min(selectedRange.location, string.utf16.count), length: 0)
            keepInsertionPointVisible()
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                  let character = event.charactersIgnoringModifiers?.lowercased() else {
                return super.performKeyEquivalent(with: event)
            }

            switch character {
            case "x":
                cut(nil)
                return true
            case "c":
                copy(nil)
                return true
            case "v":
                paste(nil)
                return true
            case "a":
                selectAll(nil)
                return true
            case "z":
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift) {
                    undoManager?.redo()
                } else {
                    undoManager?.undo()
                }
                keepInsertionPointVisible()
                return true
            default:
                return super.performKeyEquivalent(with: event)
            }
        }

        func keepInsertionPointVisible() {
            let location = min(selectedRange.location, string.utf16.count)
            scrollRangeToVisible(NSRange(location: location, length: 0))
        }

        var singleLineString: String {
            string.replacingOccurrences(of: "\n", with: "")
        }
    }
}

private struct ConversationPanel: View {
    @ObservedObject var model: FloatScopeModel
    private let bottomID = "FloatScopeConversationBottom"
    private let collapsedRenderLimit = 6
    private let initialExpandedRenderLimit = 8
    private let fullRenderLimit = 24
    @State private var renderLimit = 8
    @State private var renderRampWorkItem: DispatchWorkItem?
    @State private var scrollWorkItem: DispatchWorkItem?
    @State private var isPreparingInitialScroll = true

    var body: some View {
        let visibleMessages = Array(model.messages.suffix(renderLimit))

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
                    Image(systemName: "camera.fill")
                        .font(.caption)
                        .foregroundStyle(.cyan)
                    Spacer()
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(visibleMessages) { message in
                            MessageBubble(
                                message: message,
                                visuals: model.settings.visuals,
                                agents: model.agentConfigs,
                                onEditForResend: {
                                    model.editMessageForResend(message)
                                }
                            )
                                .id(message.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                    }
                }
                .defaultScrollAnchor(.bottom)
                .opacity(isPreparingInitialScroll ? 0.01 : 1)
                .frame(maxHeight: .infinity)
                .onAppear {
                    rampVisibleMessages(proxy)
                }
                .onChange(of: model.messages.count) { _, _ in
                    scheduleScrollToBottom(proxy, animated: false, delay: 0.04)
                }
                .onChange(of: model.messages.last?.text ?? "") { _, _ in
                    scheduleScrollToBottom(proxy, animated: false, delay: 0.12)
                }
                .onChange(of: model.isExpanded) { _, expanded in
                    if expanded {
                        rampVisibleMessages(proxy)
                    } else {
                        renderRampWorkItem?.cancel()
                        renderLimit = collapsedRenderLimit
                    }
                }
                .onChange(of: model.isLoadingHistory) { _, loading in
                    if !loading {
                        rampVisibleMessages(proxy)
                    }
                }
            }
        }
        .padding(14)
        .glassSurface(cornerRadius: 18, material: .hudWindow, strokeOpacity: 0.16)
    }

    private func rampVisibleMessages(_ proxy: ScrollViewProxy) {
        renderRampWorkItem?.cancel()
        isPreparingInitialScroll = true
        renderLimit = min(initialExpandedRenderLimit, max(initialExpandedRenderLimit, model.messages.count))
        scrollToBottom(proxy, animated: false)
        queueScrollToBottom(proxy, delay: 0.02)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            scrollToBottom(proxy, animated: false)
            isPreparingInitialScroll = false
        }

        let workItem = DispatchWorkItem {
            renderLimit = fullRenderLimit
            queueScrollToBottom(proxy, delay: 0.02)
            queueScrollToBottom(proxy, delay: 0.10)
        }
        renderRampWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: workItem)
    }

    private func scheduleScrollToBottom(_ proxy: ScrollViewProxy, animated: Bool, delay: TimeInterval) {
        scrollWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            scrollToBottom(proxy, animated: animated)
        }
        scrollWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func queueScrollToBottom(_ proxy: ScrollViewProxy, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            scrollToBottom(proxy, animated: false)
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
    let onEditForResend: () -> Void

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
        .contextMenu {
            if isUserMessage {
                Button {
                    onEditForResend()
                } label: {
                    Label(L10n.text(.rollback, language: FloatScopeSettings().appLanguage), systemImage: "arrow.uturn.backward")
                }
            }
        }
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

    private var isUserMessage: Bool {
        if case .user = message.role { return true }
        return false
    }
}

private struct AttachmentPreview: View {
    let attachment: ChatAttachment
    @State private var image: NSImage?
    @State private var didAttemptLoad = false

    var body: some View {
        if attachment.isImage {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(0.12))
                        .overlay {
                            ProgressView()
                                .controlSize(.small)
                                .opacity(didAttemptLoad ? 0 : 1)
                        }
                }
            }
            .frame(maxWidth: 220, maxHeight: 150, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            }
            .task(id: attachment.url) {
                await loadImage()
            }
        } else {
            Label(attachment.filename, systemImage: "doc")
                .font(.caption)
                .lineLimit(1)
        }
    }

    private func loadImage() async {
        guard image == nil else { return }
        let url = attachment.url
        let data = await Task.detached(priority: .utility) {
            try? Data(contentsOf: url)
        }.value

        await MainActor.run {
            didAttemptLoad = true
            image = data.flatMap(NSImage.init(data:))
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
        .help(L10n.text(.modelPickerHelp, language: model.settings.appLanguage))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            modelPickerContent
                .padding(10)
        }
    }

    @ViewBuilder
    private var modelPickerContent: some View {
        if model.selectedAgentID == model.agentConfigs.first?.id {
            ScrollView {
                agentColumn(agent: model.agentConfigs.first, kind: .codex)
            }
            .frame(width: 250, height: 360)
        } else if model.selectedAgentID == model.agentConfigs.dropFirst().first?.id {
            ScrollView {
                agentColumn(agent: model.agentConfigs.dropFirst().first, kind: .opencode)
            }
            .frame(width: 270, height: 430)
        } else if model.selectedAgentID == "group" || model.selectedAgentID == "auto" {
            HStack(alignment: .top, spacing: 12) {
                ScrollView {
                    agentColumn(agent: model.agentConfigs.first, kind: .codex)
                }
                .frame(width: 230, height: 430)

                Divider()
                    .frame(height: 430)

                ScrollView {
                    agentColumn(agent: model.agentConfigs.dropFirst().first, kind: .opencode)
                }
                .frame(width: 260, height: 430)
            }
        } else if let agent = model.agentConfigs.first(where: { $0.id == model.selectedAgentID }) {
            ScrollView {
                genericAgentColumn(agent: agent)
            }
            .frame(width: 250, height: 220)
        } else {
            Text(L10n.text(.configuredInSettings, language: model.settings.appLanguage))
                .padding(.horizontal, 10)
        }
    }

    private enum ModelColumnKind {
        case codex
        case opencode
    }

    @ViewBuilder
    private func agentColumn(agent: AgentRuntimeConfig?, kind: ModelColumnKind) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            agentHeader(agent)
            switch kind {
            case .codex:
                codexSection
            case .opencode:
                secondarySections
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func agentHeader(_ agent: AgentRuntimeConfig?) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(hex: agent?.color ?? "#8E8E93"))
                .frame(width: 9, height: 9)
            Text(agent?.displayName ?? L10n.text(.agentFallback, language: model.settings.appLanguage))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 2)
    }

    private func genericAgentColumn(agent: AgentRuntimeConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            agentHeader(agent)
            Text(agent.model ?? L10n.text(.configuredInSettings, language: model.settings.appLanguage))
                .font(.caption)
                .padding(.horizontal, 10)
            Text(agent.effort ?? agent.variant ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        Text(L10n.text(.effort, language: model.settings.appLanguage))
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
    private var secondarySections: some View {
        Text("OpenCode Zen")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
        ForEach(OpenCodeModelPreset.opencodeZenCases) { preset in
            Button {
                model.setSecondaryModelPreset(preset)
                isPresented = false
            } label: {
                modelRow(title: preset.displayName, selected: preset == model.secondaryModelPreset)
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
                model.setSecondaryModelPreset(preset)
            } label: {
                modelRow(title: preset.displayName, selected: preset == model.secondaryModelPreset)
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
                model.setSecondaryModelPreset(preset)
            } label: {
                modelRow(title: preset.displayName, selected: preset == model.secondaryModelPreset)
            }
            .buttonStyle(.plain)
        }
        Divider().padding(.vertical, 2)
        Text(L10n.text(.variant, language: model.settings.appLanguage))
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
        ForEach(OpenCodeVariantPreset.allCases) { preset in
            Button {
                model.setSecondaryVariantPreset(preset)
                isPresented = false
            } label: {
                modelRow(title: preset.displayName, selected: preset == model.secondaryVariantPreset)
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
        .contentShape(Rectangle())
    }
}

struct HistoryPickerView: View {
    @ObservedObject var model: FloatScopeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.text(.conversationHistory, language: model.settings.appLanguage))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    model.refreshHistory()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help(L10n.text(.refresh, language: model.settings.appLanguage))
            }

            if model.historyEntries.isEmpty {
                if model.isLoadingHistory {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        L10n.text(.noHistoryTitle, language: model.settings.appLanguage),
                        systemImage: "clock",
                        description: Text(L10n.text(.noHistoryDescription, language: model.settings.appLanguage))
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.historyEntries) { entry in
                            Button {
                                model.selectHistory(entry)
                            } label: {
                                HistoryRow(entry: entry, agents: model.agentConfigs, language: model.settings.appLanguage)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    model.deleteHistory(entry)
                                } label: {
                                    Label(L10n.text(.delete, language: model.settings.appLanguage), systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack {
                Spacer()
                Button(L10n.text(.close, language: model.settings.appLanguage)) {
                    model.showHistory = false
                }
            }
        }
        .padding(18)
        .frame(width: 460, height: 520)
        .background {
            ZStack {
                FrostedGlassBackground(material: .hudWindow)
                Color(hex: model.settings.userColorHex).opacity(0.16)
                Color.black.opacity(0.08)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 1)
        }
    }
}

private struct HistoryRow: View {
    let entry: ConversationHistoryEntry
    let agents: [AgentRuntimeConfig]
    let language: AppLanguage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            historyIcon
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
                Text("\(entry.messageCount) \(L10n.text(.messages, language: language))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var historyIcon: some View {
        if entry.title.hasPrefix("群聊 ") || entry.agentCount > 1 {
            GroupHistoryIcon(colors: groupColors, hasMore: groupColors.count > 3)
        } else if entry.codexThreadID != nil {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: agents.first?.color ?? "#FF6FB7"))
        } else if entry.opencodeSessionID != nil {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: agents.dropFirst().first?.color ?? "#A85BFF"))
        } else {
            Image(systemName: "bubble.left")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var groupColors: [Color] {
        var colors: [Color] = []
        if entry.codexThreadID != nil || entry.title.hasPrefix("群聊 ") {
            if let color = agents.first?.color {
                colors.append(Color(hex: color))
            }
        }
        if entry.opencodeSessionID != nil || entry.title.hasPrefix("群聊 ") {
            if let color = agents.dropFirst().first?.color {
                colors.append(Color(hex: color))
            }
        }
        if entry.title.hasPrefix("群聊 "), agents.count > 2 {
            colors.append(contentsOf: agents.dropFirst(2).map { Color(hex: $0.color) })
        }
        return colors.isEmpty ? [.secondary] : colors
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

private struct GroupHistoryIcon: View {
    let colors: [Color]
    let hasMore: Bool

    var body: some View {
        ZStack {
            ForEach(Array(colors.prefix(3).enumerated()), id: \.offset) { index, color in
                Circle()
                    .fill(color)
                    .frame(width: 8.5, height: 8.5)
                    .offset(offset(for: index, count: min(colors.count, 3)))
                    .overlay {
                        Circle().stroke(.white.opacity(0.45), lineWidth: 0.7)
                    }
            }

            if hasMore {
                Text("+")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 9, height: 9)
                    .background(.secondary, in: Circle())
                    .offset(x: 5, y: 5)
            }
        }
        .frame(width: 16, height: 16)
    }

    private func offset(for index: Int, count: Int) -> CGSize {
        if count <= 1 {
            return .zero
        }
        if count == 2 {
            return index == 0 ? CGSize(width: -3, height: -2) : CGSize(width: 3, height: 3)
        }
        switch index {
        case 0: return CGSize(width: -4, height: -3)
        case 1: return CGSize(width: 4, height: -3)
        default: return CGSize(width: 0, height: 4)
        }
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
                .help(L10n.text(.collapseEditor, language: model.settings.appLanguage))

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
                .help(L10n.text(.send, language: model.settings.appLanguage))
                .disabled(model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.pendingAttachments.isEmpty)
            }

            AppKitTextEditor(text: $model.inputText)
                .padding(12)
                .glassSurface(cornerRadius: 16, material: .popover, strokeOpacity: 0.16)
        }
        .padding(18)
        .frame(width: 640, height: 430)
        .glassSurface(cornerRadius: 22, material: .hudWindow, strokeOpacity: 0.18)
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

        let textView = ShortcutTextView()
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

    final class ShortcutTextView: NSTextView {
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                  let character = event.charactersIgnoringModifiers?.lowercased() else {
                return super.performKeyEquivalent(with: event)
            }

            switch character {
            case "x":
                cut(nil)
                return true
            case "c":
                copy(nil)
                return true
            case "v":
                paste(nil)
                return true
            case "a":
                selectAll(nil)
                return true
            case "z":
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift) {
                    undoManager?.redo()
                } else {
                    undoManager?.undo()
                }
                return true
            default:
                return super.performKeyEquivalent(with: event)
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: FloatScopeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.text(.settingsTitle, language: model.settings.appLanguage))
                    .font(.headline)

                Picker(L10n.text(.appLanguage, language: model.settings.appLanguage), selection: Binding(
                    get: { model.settings.appLanguage },
                    set: { model.settings.appLanguage = $0 }
                )) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }

                GroupBox(L10n.text(.agents, language: model.settings.appLanguage)) {
                    VStack(alignment: .leading, spacing: 12) {
                        colorField(L10n.text(.userColor, language: model.settings.appLanguage), color: model.settings.visuals.userColor, text: Binding(
                            get: { model.settings.userColorHex },
                            set: { model.settings.userColorHex = $0 }
                        ))

                        ForEach(Array(model.agentConfigs.enumerated()), id: \.element.id) { index, agent in
                            AgentConfigCard(
                                title: "\(L10n.text(.agentTitle, language: model.settings.appLanguage)) \(index + 1)",
                                config: binding(for: agent.id),
                                canRemove: model.agentConfigs.count > 1,
                                language: model.settings.appLanguage,
                                onRemove: {
                                    model.removeAgentConfig(id: agent.id)
                                }
                            )
                        }

                        Button {
                            model.addAgentConfig()
                        } label: {
                            Label(L10n.text(.addAgent, language: model.settings.appLanguage), systemImage: "plus.circle")
                        }
                    }
                    .padding(.vertical, 4)
                }

                Picker(L10n.text(.agent1Model, language: model.settings.appLanguage), selection: $model.codexModelPreset) {
                    ForEach(CodexModelPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .onChange(of: model.codexModelPreset) { _, value in
                    model.setCodexModelPreset(value)
                }

                Picker(L10n.text(.agent1Effort, language: model.settings.appLanguage), selection: $model.codexEffortPreset) {
                    ForEach(ReasoningEffortPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .onChange(of: model.codexEffortPreset) { _, value in
                    model.setCodexEffortPreset(value)
                }

                Picker(L10n.text(.agent2Model, language: model.settings.appLanguage), selection: $model.secondaryModelPreset) {
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
                .onChange(of: model.secondaryModelPreset) { _, value in
                    model.setSecondaryModelPreset(value)
                }

                Picker(L10n.text(.agent2Variant, language: model.settings.appLanguage), selection: $model.secondaryVariantPreset) {
                    ForEach(OpenCodeVariantPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .onChange(of: model.secondaryVariantPreset) { _, value in
                    model.setSecondaryVariantPreset(value)
                }

                settingsTextField(L10n.text(.conversationProject, language: model.settings.appLanguage), text: Binding(
                    get: { model.settings.conversationRoot },
                    set: { model.settings.conversationRoot = $0 }
                ))

                settingsTextField(L10n.text(.toggleShortcut, language: model.settings.appLanguage), text: Binding(
                    get: { model.settings.toggleShortcut },
                    set: { model.settings.toggleShortcut = $0 }
                ))

                Toggle(L10n.text(.launchAtLogin, language: model.settings.appLanguage), isOn: Binding(
                    get: { model.settings.launchAtLogin },
                    set: { model.settings.launchAtLogin = $0 }
                ))

                Toggle(L10n.text(.showSystemMessages, language: model.settings.appLanguage), isOn: Binding(
                    get: { model.settings.showSystemMessages },
                    set: { model.settings.showSystemMessages = $0 }
                ))

                Toggle(L10n.text(.screenReplayCache, language: model.settings.appLanguage), isOn: Binding(
                    get: { model.settings.screenReplayCacheEnabled },
                    set: { model.settings.screenReplayCacheEnabled = $0 }
                ))

                HStack {
                    Text(L10n.text(.opacity, language: model.settings.appLanguage))
                    Slider(value: Binding(
                        get: { Double(model.settings.capsuleOpacity) },
                        set: { model.settings.capsuleOpacity = CGFloat($0) }
                    ), in: 0.65...1)
                }

                HStack {
                    Text(L10n.text(.watchInterval, language: model.settings.appLanguage))
                    TextField("60", value: Binding(
                        get: { model.settings.watchDefaultInterval },
                        set: { model.settings.watchDefaultInterval = $0 }
                    ), format: .number)
                    .frame(width: 80)
                    Text(L10n.text(.seconds, language: model.settings.appLanguage))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text(L10n.text(.autoCollapse, language: model.settings.appLanguage))
                    TextField("8", value: Binding(
                        get: { model.settings.autoCollapseAfterReply },
                        set: { model.settings.autoCollapseAfterReply = $0 }
                    ), format: .number)
                    .frame(width: 80)
                    Text(L10n.text(.seconds, language: model.settings.appLanguage))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Button(L10n.text(.cancel, language: model.settings.appLanguage)) {
                        model.showSettings = false
                    }
                    Button(L10n.text(.apply, language: model.settings.appLanguage)) {
                        model.applySettings()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
        }
        .background {
            ZStack {
                FrostedGlassBackground(material: .hudWindow)
                Color(hex: model.settings.userColorHex).opacity(0.16)
                Color.black.opacity(0.08)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 1)
        }
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
    let language: AppLanguage
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
                    .help(L10n.text(.removeAgent, language: language))
                }
            }

            row(L10n.text(.id, language: language)) {
                TextField("agent-id", text: $config.id)
            }
            row(L10n.text(.name, language: language)) {
                TextField("Agent Name", text: $config.displayName)
            }
            row(L10n.text(.kind, language: language)) {
                if config.kind.hasPrefix("codex-") {
                    Text(config.kind == "codex-cli-resume" ? "Codex Lightweight CLI" : "Codex App Server")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("", selection: $config.kind) {
                        Text("OpenCode Run").tag("opencode-run")
                        Text("Generic CLI").tag("generic-cli")
                        Text("Claude Code").tag("claude-code")
                        Text("OpenClaw").tag("openclaw")
                    }
                    .labelsHidden()
                }
            }
            row(L10n.text(.color, language: language)) {
                HStack {
                    Circle()
                        .fill(Color(hex: config.color))
                        .frame(width: 14, height: 14)
                    TextField("#RRGGBB", text: $config.color)
                }
            }
            row(L10n.text(.executable, language: language)) {
                TextField("/path/to/cli", text: $config.executablePath)
            }
            row("App") {
                TextField("/Applications/App.app", text: Binding(
                    get: { config.appBundlePath ?? "" },
                    set: { config.appBundlePath = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                ))
            }
            row(L10n.text(.model, language: language)) {
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
            row(L10n.text(.effort, language: language)) {
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
