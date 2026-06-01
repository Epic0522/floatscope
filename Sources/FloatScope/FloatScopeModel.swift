import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class FloatScopeModel: ObservableObject {
    @Published var selectedAgent: AgentID
    @Published var selectedAgentID: String
    @Published var messages: [ChatMessage] = []
    @Published var inputText = ""
    @Published var showLongInputEditor = false
    @Published var isExpanded = false
    @Published var showSettings = false
    @Published var moods: [String: AgentMoodState] = [:]
    @Published var watchMode: WatchIntervalMode?
    @Published var settings = FloatScopeSettings()
    @Published var codexModelPreset: CodexModelPreset
    @Published var codexEffortPreset: ReasoningEffortPreset
    @Published var secondaryModelPreset: OpenCodeModelPreset
    @Published var secondaryVariantPreset: OpenCodeVariantPreset
    @Published var pendingAttachments: [URL] = []
    @Published var agentConfigs: [AgentRuntimeConfig]
    @Published var showHistory = false
    @Published var historyEntries: [ConversationHistoryEntry] = []
    @Published var isLoadingHistory = false
    @Published var pendingResponseAgents: Set<String> = []
    var onExpansionChanged: ((Bool) -> Void)?

    private let bridge = AgentBridge()
    private let screenWatcher = ScreenWatcher()
    private var scheduler: WatchScheduler?
    private var currentAgentResponse: [String: UUID] = [:]

    init() {
        AgentHubConfigStore.ensureUserConfig()
        let storedAgent = AgentID(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.selectedAgent) ?? "")
        let storedDefault = AgentID(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.defaultAgent) ?? "") ?? .primary
        selectedAgent = storedAgent ?? storedDefault
        selectedAgentID = UserDefaults.standard.string(forKey: SettingsKeys.selectedAgentID) ?? "agent1"
        let storedSettings = FloatScopeSettings()
        codexModelPreset = storedSettings.codexModelPreset
        codexEffortPreset = storedSettings.codexEffortPreset
        secondaryModelPreset = storedSettings.secondaryModelPreset
        secondaryVariantPreset = storedSettings.secondaryVariantPreset
        agentConfigs = AgentHubConfigStore.load().agents
        if selectedAgentID == "auto" {
            selectedAgentID = "group"
            UserDefaults.standard.set(selectedAgentID, forKey: SettingsKeys.selectedAgentID)
        }
        if !agentConfigs.contains(where: { $0.id == selectedAgentID }) && !isGroupAgentID(selectedAgentID) {
            selectedAgentID = agentConfigs.first?.id ?? "agent1"
        }
        messages = TranscriptStore.load()
        resetMoodMap()
        bridge.configure(config: AgentHubConfig(version: 1, conversationRoot: settings.conversationRoot, agents: agentConfigs))
        bridge.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleBridgeEvent(event)
            }
        }
        scheduler = WatchScheduler(watcher: screenWatcher) { [weak self] result in
            Task { @MainActor in
                self?.handleWatchCapture(result)
            }
        }
        screenWatcher.setRollingCacheEnabled(settings.screenReplayCacheEnabled)
        bridge.startAll()
        appendSystem(L10n.text(.ready, language: settings.appLanguage))
    }

    func stop() {
        bridge.stopAll()
        scheduler?.stop()
        screenWatcher.stopRollingCache()
    }

    func sendCurrentInput() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        inputText = ""
        showLongInputEditor = false
        pendingAttachments.removeAll()
        expand()

        if isScreenCue(trimmed) {
            sendWithFreshScreenCapture(prompt: trimmed)
            return
        }

        let agents = resolveAgentIDs(for: trimmed)
        guard !agents.isEmpty else { return }
        let message = trimmed.isEmpty ? L10n.text(.attachmentPrompt, language: settings.appLanguage) : trimmed
        if isGroupAgentID(selectedAgentID), agents.count > 1 {
            bridge.prepareGroupConversationIfNeeded()
        }
        appendUser(message, attachments: attachments)
        pendingResponseAgents.formUnion(agents)
        for agent in agents {
            currentAgentResponse[agent] = nil
            moods[agent] = .thinking
            bridge.send(agent: agent, message: outboundMessage(message, groupAgents: agents), attachments: attachments, codexModelPreset: codexModelPreset, codexEffortPreset: codexEffortPreset, secondaryModelPreset: secondaryModelPreset, secondaryVariantPreset: secondaryVariantPreset)
        }
    }

    func editMessageForResend(_ message: ChatMessage) {
        guard case .user = message.role,
              let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let removedMessages = messages[index...]
        let turnsToRollback = removedMessages.reduce(0) { count, item in
            if case .user = item.role { return count + 1 }
            return count
        }
        let targetAgents = resolveAgentIDs(for: "")

        inputText = message.text
        pendingAttachments = message.attachments
            .map(\.url)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        showLongInputEditor = needsLongInputEditor
        messages.removeSubrange(index..<messages.endIndex)
        currentAgentResponse.removeAll()
        pendingResponseAgents.removeAll()
        for agent in targetAgents {
            moods[agent] = .idle
        }
        saveTranscript()
        bridge.rollback(agents: targetAgents, numTurns: turnsToRollback)
        expand()
    }

    func manualScreenCapture() {
        sendWithFreshScreenCapture(prompt: settings.appLanguage.isChinese ? "你看这个" : "Look at this")
    }

    func addAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                self?.pendingAttachments.append(contentsOf: panel.urls)
                self?.expand()
            }
        }
    }

    func removeAttachment(_ url: URL) {
        pendingAttachments.removeAll { $0 == url }
    }

    func addAttachmentURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingAttachments.append(contentsOf: urls.compactMap(Self.persistAttachmentIfNeeded))
        expand()
    }

    func addAttachmentProviders(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else {
                        url = item as? URL
                    }
                    guard let url else { return }
                    Task { @MainActor in
                        self?.addAttachmentURLs([url])
                    }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                accepted = true
                provider.loadObject(ofClass: NSImage.self) { [weak self] object, _ in
                    guard let image = object as? NSImage,
                          let data = image.tiffRepresentation,
                          let url = Self.writePastedImageData(data) else { return }
                    Task { @MainActor in
                        self?.addAttachmentURLs([url])
                    }
                }
            }
        }
        return accepted
    }

    var needsLongInputEditor: Bool {
        inputText.count > 80 || inputText.contains("\n")
    }

    func openLongInputEditor() {
        showLongInputEditor = true
        expand()
    }

    func importPasteboardAttachments() -> Bool {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            addAttachmentURLs(urls)
            return true
        }
        if let image = NSImage(pasteboard: pasteboard),
           let data = image.tiffRepresentation,
           let url = Self.writePastedImageData(data) {
            addAttachmentURLs([url])
            return true
        }
        return false
    }

    func applySettings() {
        agentConfigs = normalizedAgentConfigs(agentConfigs)
        persistAgentConfigs()
        resetMoodMap()
        bridge.configure(config: AgentHubConfig(version: 1, conversationRoot: settings.conversationRoot, agents: agentConfigs))
        bridge.startAll()
        settings.codexModelPreset = codexModelPreset
        settings.codexEffortPreset = codexEffortPreset
        settings.secondaryModelPreset = secondaryModelPreset
        settings.secondaryVariantPreset = secondaryVariantPreset
        screenWatcher.setRollingCacheEnabled(settings.screenReplayCacheEnabled)
        UserDefaults.standard.set(selectedAgent.rawValue, forKey: SettingsKeys.selectedAgent)
        UserDefaults.standard.set(selectedAgentID, forKey: SettingsKeys.selectedAgentID)
        NotificationCenter.default.post(name: .floatScopeSettingsApplied, object: nil)
        showSettings = false
    }

    func addAgentConfig() {
        var nextIndex = agentConfigs.count + 1
        var agent = AgentHubConfigStore.makeAgent(index: nextIndex)
        while agentConfigs.contains(where: { $0.id == agent.id }) {
            nextIndex += 1
            agent = AgentHubConfigStore.makeAgent(index: nextIndex)
        }
        agentConfigs.append(agent)
        resetMoodMap()
    }

    func removeAgentConfig(id: String) {
        guard agentConfigs.count > 1 else { return }
        agentConfigs.removeAll { $0.id == id }
        if selectedAgentID == id {
            selectedAgentID = agentConfigs.first?.id ?? "agent1"
        }
        resetMoodMap()
    }

    func setCodexModelPreset(_ preset: CodexModelPreset) {
        codexModelPreset = preset
        settings.codexModelPreset = preset
        updateAgentConfig(id: agentConfigs.first?.id, model: preset.codexModel, effort: nil, variant: nil)
    }

    func setCodexEffortPreset(_ preset: ReasoningEffortPreset) {
        codexEffortPreset = preset
        settings.codexEffortPreset = preset
        updateAgentConfig(id: agentConfigs.first?.id, model: nil, effort: preset.rawValue, variant: nil)
    }

    func setSecondaryModelPreset(_ preset: OpenCodeModelPreset) {
        secondaryModelPreset = preset
        settings.secondaryModelPreset = preset
        updateAgentConfig(id: agentConfigs.dropFirst().first?.id, model: preset.modelIdentifier, effort: nil, variant: nil)
    }

    func setSecondaryVariantPreset(_ preset: OpenCodeVariantPreset) {
        secondaryVariantPreset = preset
        settings.secondaryVariantPreset = preset
        updateAgentConfig(id: agentConfigs.dropFirst().first?.id, model: nil, effort: nil, variant: preset.rawValue)
    }

    func startNewConversation() {
        bridge.startNewConversation(group: isGroupAgentID(selectedAgentID))
        currentAgentResponse.removeAll()
        pendingResponseAgents.removeAll()
        messages.removeAll()
        TranscriptStore.clear()
        appendSystem(L10n.text(.newConversationStarted, language: settings.appLanguage))
        expand()
    }

    func toggleDefaultScreenWatch() {
        if watchMode != nil {
            scheduler?.stop()
            watchMode = nil
            resetMoodMap()
            appendSystem(L10n.text(.screenWatchStopped, language: settings.appLanguage))
            return
        }

        let mode = WatchIntervalMode.fixed(settings.watchDefaultInterval)
        watchMode = mode
        scheduler?.start(intervalMode: mode)
        appendSystem(L10n.text(.screenWatchStarted, language: settings.appLanguage))
    }

    func openHistoryPicker() {
        refreshHistory()
        showHistory = true
    }

    func refreshHistory() {
        let root = settings.conversationRoot
        let agents = agentConfigs
        isLoadingHistory = true
        Task.detached(priority: .userInitiated) {
            let entries = ConversationHistoryStore.list(conversationRoot: root, agents: agents)
            await MainActor.run {
                self.historyEntries = entries
                self.isLoadingHistory = false
            }
        }
    }

    func selectHistory(_ entry: ConversationHistoryEntry) {
        bridge.selectConversation(entry)
        currentAgentResponse.removeAll()
        let agents = agentConfigs
        if entry.title.hasPrefix("群聊 ") || (entry.codexThreadID != nil && entry.opencodeSessionID != nil) {
            selectedAgentID = "group"
            UserDefaults.standard.set(selectedAgentID, forKey: SettingsKeys.selectedAgentID)
        } else if entry.codexThreadID != nil, entry.opencodeSessionID == nil {
            selectedAgentID = agents.first?.id ?? selectedAgentID
            UserDefaults.standard.set(selectedAgentID, forKey: SettingsKeys.selectedAgentID)
        } else if entry.opencodeSessionID != nil, entry.codexThreadID == nil {
            selectedAgentID = agents.dropFirst().first?.id ?? selectedAgentID
            UserDefaults.standard.set(selectedAgentID, forKey: SettingsKeys.selectedAgentID)
        }
        messages.removeAll()
        TranscriptStore.clear()
        isLoadingHistory = true
        showHistory = false
        expand()
        Task.detached(priority: .userInitiated) {
            let loaded = ConversationHistoryStore.loadMessages(for: entry, agents: agents)
            await MainActor.run {
                self.messages = loaded
                self.trimMessages()
                self.saveTranscript()
                self.isLoadingHistory = false
            }
        }
    }

    func deleteHistory(_ entry: ConversationHistoryEntry) {
        let root = settings.conversationRoot
        let agents = agentConfigs
        historyEntries.removeAll { $0.id == entry.id }
        Task.detached(priority: .userInitiated) {
            ConversationHistoryStore.delete(entry)
            let entries = ConversationHistoryStore.list(conversationRoot: root, agents: agents)
            await MainActor.run {
                self.historyEntries = entries
            }
        }
    }

    func expand() {
        guard !isExpanded else { return }
        isExpanded = true
        onExpansionChanged?(true)
    }

    func collapse() {
        guard !showSettings else { return }
        guard isExpanded else { return }
        isExpanded = false
        onExpansionChanged?(false)
    }

    func toggleExpanded() {
        isExpanded.toggle()
        onExpansionChanged?(isExpanded)
    }

    private func persistAgentConfigs() {
        if agentConfigs.indices.contains(0) {
            settings.primaryDisplayName = agentConfigs[0].displayName
            settings.primaryColorHex = agentConfigs[0].color
            settings.codexPath = agentConfigs[0].executablePath
        }
        if agentConfigs.indices.contains(1) {
            settings.secondaryDisplayName = agentConfigs[1].displayName
            settings.secondaryColorHex = agentConfigs[1].color
            settings.opencodePath = agentConfigs[1].executablePath
        }
        let config = AgentHubConfig(version: 1, conversationRoot: settings.conversationRoot, agents: agentConfigs)
        AgentHubConfigStore.save(config)
    }

    private func updateAgentConfig(id: String?, model: String?, effort: String?, variant: String?) {
        guard let id,
              let index = agentConfigs.firstIndex(where: { $0.id == id }) else { return }
        if let model {
            agentConfigs[index].model = model
        }
        if let effort {
            agentConfigs[index].effort = effort
        }
        if let variant {
            agentConfigs[index].variant = variant
        }
        AgentHubConfigStore.save(AgentHubConfig(version: 1, conversationRoot: settings.conversationRoot, agents: agentConfigs))
    }

    private func normalizedAgentConfigs(_ configs: [AgentRuntimeConfig]) -> [AgentRuntimeConfig] {
        var seen: Set<String> = []
        return configs.enumerated().map { index, config in
            var normalized = config
            let fallbackID = "agent\(index + 1)"
            let trimmedID = normalized.id.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.id = trimmedID.isEmpty ? fallbackID : trimmedID
            if seen.contains(normalized.id) {
                normalized.id = fallbackID
            }
            while seen.contains(normalized.id) {
                normalized.id += "-copy"
            }
            seen.insert(normalized.id)
            if normalized.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                normalized.displayName = "Agent \(index + 1)"
            }
            return normalized
        }
    }

    private func isScreenCue(_ text: String) -> Bool {
        let cues = ["你看这个", "看屏幕", "看看这个", "look at this", "check screen"]
        return cues.contains { text.localizedCaseInsensitiveContains($0) }
    }

    private func sendWithFreshScreenCapture(prompt: String) {
        let agents = resolveAgentIDs(for: prompt)
        guard !agents.isEmpty else { return }
        if isGroupAgentID(selectedAgentID), agents.count > 1 {
            bridge.prepareGroupConversationIfNeeded()
        }
        appendUser(prompt)
        pendingResponseAgents.formUnion(agents)
        for agent in agents {
            currentAgentResponse[agent] = nil
            moods[agent] = .watching
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await screenWatcher.captureRecentOrFresh()
                let stableURL = Self.persistAttachmentIfNeeded(url) ?? url
                if let index = messages.lastIndex(where: { $0.role.isUser && $0.text == prompt && $0.attachments.isEmpty }) {
                    messages[index].attachments = [Self.chatAttachment(for: stableURL)]
                    saveTranscript()
                }
                for agent in agents {
                    bridge.send(agent: agent, message: outboundMessage(prompt, groupAgents: agents), attachments: [stableURL], codexModelPreset: codexModelPreset, codexEffortPreset: codexEffortPreset, secondaryModelPreset: secondaryModelPreset, secondaryVariantPreset: secondaryVariantPreset)
                }
                appendSystem("\(L10n.text(.capturedScreen, language: settings.appLanguage)): \(url.lastPathComponent)")
                for agent in agents {
                    moods[agent] = .thinking
                }
            } catch {
                for agent in agents {
                    pendingResponseAgents.remove(agent)
                    moods[agent] = .error
                }
                appendSystem(error.localizedDescription)
            }
        }
    }

    private func handleWatchCapture(_ result: Result<URL, Error>) {
        let agents = resolveAgentIDs(for: "")
        guard !agents.isEmpty else { return }
        if isGroupAgentID(selectedAgentID), agents.count > 1 {
            bridge.prepareGroupConversationIfNeeded()
        }
        switch result {
        case .success(let url):
            pendingResponseAgents.formUnion(agents)
            for agent in agents {
                moods[agent] = .watching
                currentAgentResponse[agent] = nil
                let message = L10n.text(.watchObservationPrompt, language: settings.appLanguage)
                bridge.send(agent: agent, message: outboundMessage(message, groupAgents: agents, currentMessageAlreadyAppended: false), attachments: [url], codexModelPreset: codexModelPreset, codexEffortPreset: codexEffortPreset, secondaryModelPreset: secondaryModelPreset, secondaryVariantPreset: secondaryVariantPreset)
            }
            appendSystem(L10n.text(.watchCaptureSent, language: settings.appLanguage))
            for agent in agents {
                moods[agent] = .thinking
            }
        case .failure(let error):
            for agent in agents {
                pendingResponseAgents.remove(agent)
                moods[agent] = .error
            }
            appendSystem(error.localizedDescription)
            scheduler?.stop()
            watchMode = nil
        }
    }

    private func resolveAgentIDs(for text: String) -> [String] {
        if isGroupAgentID(selectedAgentID) {
            return agentConfigs.map(\.id)
        }
        return [resolveAgentID(for: text)]
    }

    private func resolveAgentID(for text: String) -> String {
        if !isGroupAgentID(selectedAgentID) {
            return selectedAgentID
        }
        let lower = text.lowercased()
        if let matched = agentConfigs.first(where: { lower.contains($0.id.lowercased()) || lower.contains($0.displayName.lowercased()) }) {
            return matched.id
        }
        return agentConfigs.first?.id ?? "agent1"
    }

    private func isGroupAgentID(_ id: String) -> Bool {
        id == "group" || id == "auto"
    }

    private func outboundMessage(_ message: String, groupAgents: [String], currentMessageAlreadyAppended: Bool = true) -> String {
        guard isGroupAgentID(selectedAgentID), groupAgents.count > 1 else {
            return message
        }

        guard let context = groupContextTranscript(currentMessageAlreadyAppended: currentMessageAlreadyAppended) else {
            return message
        }
        let attachmentNote = currentMessageAlreadyAppended ? currentAttachmentNote() : ""
        return """
        \(message)\(attachmentNote)

        <!-- FloatScope group context. Reference only. Do not mention this block.
        \(context)
        -->
        """
    }

    private func groupContextTranscript(currentMessageAlreadyAppended: Bool) -> String? {
        let sourceMessages = currentMessageAlreadyAppended ? Array(messages.dropLast()) : messages
        let recentMessages = sourceMessages
            .filter { message in
                switch message.role {
                case .system:
                    return false
                case .user, .agent:
                    return !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.attachments.isEmpty
                }
            }
            .suffix(20)

        guard !recentMessages.isEmpty else { return nil }

        let lines = recentMessages.map { message in
            let speaker: String
            switch message.role {
            case .user:
                speaker = "User"
            case .agent(let agent):
                speaker = name(for: agent)
            case .system:
                speaker = "System"
            }

            let text = Self.compactedContextText(message.text)
            let attachments = message.attachments.isEmpty
                ? ""
                : " [attachments: \(message.attachments.map(\.filename).joined(separator: ", "))]"
            return "\(speaker): \(text)\(attachments)"
        }

        return Self.truncatedContext(lines.joined(separator: "\n"))
    }

    private func currentAttachmentNote() -> String {
        guard let current = messages.last, !current.attachments.isEmpty else { return "" }
        let names = current.attachments.map(\.filename).joined(separator: ", ")
        return "\n\(L10n.text(.currentMessageAttachments, language: settings.appLanguage)): \(names)"
    }

    private static func compactedContextText(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n\n+", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > 260 else { return normalized }
        let index = normalized.index(normalized.startIndex, offsetBy: 260)
        return String(normalized[..<index]) + "..."
    }

    private static func truncatedContext(_ text: String) -> String {
        guard text.count > 3_200 else { return text }
        let index = text.index(text.endIndex, offsetBy: -3_200)
        return "...[\(L10n.text(.earlierGroupContextTruncated))]\n" + String(text[index...])
    }

    private func handleBridgeEvent(_ event: AgentBridgeEvent) {
        switch event {
        case .started(let agent):
            moods[agent] = .idle
            appendSystem("\(name(for: agent)) \(L10n.text(.sessionStarted, language: settings.appLanguage))")
        case .streamDelta(let agent, let delta):
            moods[agent] = .speaking
            expand()
            appendAgentDelta(agent: agent, delta: delta)
        case .completed(let agent):
            pendingResponseAgents.remove(agent)
            moods[agent] = .idle
        case .failed(let agent, let message):
            pendingResponseAgents.remove(agent)
            moods[agent] = .error
            appendSystem("\(name(for: agent)): \(message)")
        }
    }

    private func name(for agent: String) -> String {
        agentConfigs.first(where: { $0.id == agent })?.displayName ?? agent
    }

    private func appendUser(_ text: String, attachments: [URL] = []) {
        messages.append(ChatMessage(role: .user, text: text, attachments: attachments.map(Self.chatAttachment)))
        trimMessages()
        saveTranscript()
    }

    private func appendSystem(_ text: String) {
        guard settings.showSystemMessages else { return }
        messages.append(ChatMessage(role: .system, text: text))
        trimMessages()
        saveTranscript()
    }

    private func appendAgentDelta(agent: String, delta: String) {
        let cleaned = delta.replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if let id = currentAgentResponse[agent],
           let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text += cleaned
        } else {
            let message = ChatMessage(role: .agent(agent), text: cleaned)
            currentAgentResponse[agent] = message.id
            messages.append(message)
        }
        trimMessages()
        saveTranscript()
        expand()
    }

    private func trimMessages() {
        if messages.count > 80 {
            messages.removeFirst(messages.count - 80)
        }
    }

    private func saveTranscript() {
        TranscriptStore.save(messages)
    }

    private func resetMoodMap() {
        pendingResponseAgents.removeAll()
        moods = Dictionary(uniqueKeysWithValues: agentConfigs.map { ($0.id, AgentMoodState.idle) })
    }

    nonisolated private static func writePastedImageData(_ tiff: Data) -> URL? {
        guard let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        let directory = attachmentDirectory()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("paste-\(UUID().uuidString).png")
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    nonisolated private static func persistAttachmentIfNeeded(_ url: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let directory = attachmentDirectory()
        if url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/") {
            return url
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = url.pathExtension.isEmpty ? "dat" : url.pathExtension
            let destination = directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return url
        }
    }

    nonisolated private static func chatAttachment(for url: URL) -> ChatAttachment {
        ChatAttachment(path: url.path, filename: url.lastPathComponent, mimeType: mimeType(for: url))
    }

    nonisolated private static func attachmentDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("FloatScope")
            .appendingPathComponent("Attachments", isDirectory: true)
    }

    nonisolated private static func mimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic": "image/heic"
        case "tiff", "tif": "image/tiff"
        case "bmp": "image/bmp"
        default: nil
        }
    }
}

private extension MessageRole {
    var isUser: Bool {
        if case .user = self { return true }
        return false
    }
}
