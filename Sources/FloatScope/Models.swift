import Foundation
import SwiftUI

enum RuntimePaths {
    static var applicationSupportDirectory: URL {
        let directoryName = Bundle.main.bundleIdentifier == "local.floatscope.preview"
            ? "FloatScope Preview"
            : "FloatScope"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent(directoryName, isDirectory: true)
    }
}

struct AgentHubConfig: Codable, Sendable {
    var version: Int
    var conversationRoot: String
    var agents: [AgentRuntimeConfig]
}

struct AgentRuntimeConfig: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var kind: String
    var displayName: String
    var color: String
    var executablePath: String
    var appBundlePath: String?
    var model: String?
    var effort: String?
    var variant: String?
    var models: [String]?
    var efforts: [String]?
    var variants: [String]?
}

enum AgentHubConfigStore {
    static var configURL: URL {
        RuntimePaths.applicationSupportDirectory
            .appendingPathComponent("agents.json")
    }

    static func ensureUserConfig() {
        let url = configURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(defaultConfig)
            try data.write(to: url, options: [.atomic])
        } catch {
            // UserDefaults fallbacks keep the app usable if the config cannot be written.
        }
    }

    static func load() -> AgentHubConfig {
        ensureUserConfig()
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(AgentHubConfig.self, from: data) else {
            return defaultConfig
        }
        let migrated = migratedConfig(config)
        if migrated.agents != config.agents || migrated.version != config.version {
            save(migrated)
        }
        return migrated
    }

    static func save(_ config: AgentHubConfig) {
        do {
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: configURL, options: [.atomic])
        } catch {
            // Settings remain in memory if saving fails.
        }
    }

    static func makeAgent(index: Int) -> AgentRuntimeConfig {
        AgentRuntimeConfig(
            id: "agent\(index)",
            kind: "generic-cli",
            displayName: "Agent \(index)",
            color: "#8E8E93",
            executablePath: "",
            appBundlePath: nil,
            model: nil,
            effort: nil,
            variant: nil,
            models: [],
            efforts: [],
            variants: []
        )
    }

    static func agent(at index: Int) -> AgentRuntimeConfig {
        let config = load()
        guard config.agents.indices.contains(index) else {
            return defaultConfig.agents[index]
        }
        return config.agents[index]
    }

    private static func migratedConfig(_ config: AgentHubConfig) -> AgentHubConfig {
        var migrated = config
        migrated.agents = migrated.agents.enumerated().map { index, agent in
            var normalized = agent
            if normalized.kind == "codex-app-server" || normalized.kind == "codex-cli-resume" || normalized.kind == "codex-auto" || index == 0 {
                normalized.efforts = ReasoningEffortPreset.allCases.map(\.rawValue)
                if normalized.effort == "minimal" || normalized.effort == "none" || normalized.effort == nil {
                    normalized.effort = "low"
                }
            }
            return normalized
        }
        return migrated
    }

    static let defaultConfig = AgentHubConfig(
        version: 1,
        conversationRoot: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
            .appendingPathComponent("FloatScope Conversations")
            .path,
        agents: [
            AgentRuntimeConfig(
                id: "agent1",
                kind: "codex-app-server",
                displayName: "Agent 1",
                color: "#FF6FB7",
                executablePath: "",
                appBundlePath: nil,
                model: "gpt-5.4-mini",
                effort: "medium",
                variant: nil,
                models: CodexModelPreset.allCases.map(\.codexModel),
                efforts: ReasoningEffortPreset.allCases.map(\.rawValue),
                variants: nil
            ),
            AgentRuntimeConfig(
                id: "agent2",
                kind: "opencode-run",
                displayName: "Agent 2",
                color: "#A85BFF",
                executablePath: "",
                appBundlePath: nil,
                model: OpenCodeModelPreset.deepSeekV4FlashFree.modelIdentifier,
                effort: nil,
                variant: "auto",
                models: OpenCodeModelPreset.allCases.map(\.modelIdentifier),
                efforts: nil,
                variants: OpenCodeVariantPreset.allCases.map(\.rawValue)
            )
        ]
    )
}

enum AgentID: String, CaseIterable, Identifiable {
    case primary
    case secondary
    case auto

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .primary: "Agent 1"
        case .secondary: "Agent 2"
        case .auto: "Group"
        }
    }
}

enum ConcreteAgentID: String, CaseIterable, Identifiable {
    case primary
    case secondary

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .primary: "Agent 1"
        case .secondary: "Agent 2"
        }
    }
}

enum AgentMoodState: String {
    case idle
    case thinking
    case speaking
    case watching
    case error

    var label: String {
        switch self {
        case .idle: "Idle"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .watching: "Watching"
        case .error: "Needs attention"
        }
    }

    var color: Color {
        switch self {
        case .idle: .secondary
        case .thinking: .orange
        case .speaking: .green
        case .watching: .cyan
        case .error: .red
        }
    }
}

struct AgentVisualConfig {
    var agent1Name: String
    var agent2Name: String
    var userColorHex: String
    var agent1ColorHex: String
    var agent2ColorHex: String
    var systemColorHex: String

    var userColor: Color { Color(hex: userColorHex) }
    var primaryColor: Color { Color(hex: agent1ColorHex) }
    var secondaryColor: Color { Color(hex: agent2ColorHex) }
    var systemColor: Color { Color(hex: systemColorHex) }
}

enum CodexModelPreset: String, CaseIterable, Identifiable {
    case gpt55
    case gpt54
    case gpt54Mini
    case gpt53Codex
    case o3
    case o4Mini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gpt55: "GPT-5.5"
        case .gpt54: "GPT-5.4"
        case .gpt54Mini: "GPT-5.4 Mini"
        case .gpt53Codex: "GPT-5.3 Codex"
        case .o3: "o3"
        case .o4Mini: "o4-mini"
        }
    }

    var codexModel: String {
        switch self {
        case .gpt55: "gpt-5.5"
        case .gpt54: "gpt-5.4"
        case .gpt54Mini: "gpt-5.4-mini"
        case .gpt53Codex: "gpt-5.3-codex"
        case .o3: "o3"
        case .o4Mini: "o4-mini"
        }
    }
}

enum ReasoningEffortPreset: String, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "XHigh"
        }
    }
}

enum OpenCodeModelPreset: String, CaseIterable, Identifiable {
    case bigPickle
    case deepSeekV4FlashFree
    case mimoV25Free
    case nemotron3SuperFree
    case gemini31FlashLite
    case gemini31ProPreviewCustomTools
    case gemini35Flash
    case gemma426bA4BIT
    case gemma431bIT
    case claudeHaikuLatest
    case claudeSonnetLatest
    case claudeOpusLatest
    case openAIGPTLatest
    case openAIGPTMiniLatest
    case deepSeekR1
    case deepSeekV32

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bigPickle: "Big Pickle"
        case .deepSeekV4FlashFree: "DeepSeek V4 Flash Free"
        case .mimoV25Free: "MiMo V2.5 Free"
        case .nemotron3SuperFree: "Nemotron 3 Super Free"
        case .gemini31FlashLite: "Gemini 3.1 Flash Lite"
        case .gemini31ProPreviewCustomTools: "Gemini 3.1 Pro Preview Custom Tools"
        case .gemini35Flash: "Gemini 3.5 Flash"
        case .gemma426bA4BIT: "Gemma 4 26B A4B IT"
        case .gemma431bIT: "Gemma 4 31B IT"
        case .claudeHaikuLatest: "Claude Haiku Latest"
        case .claudeSonnetLatest: "Claude Sonnet Latest"
        case .claudeOpusLatest: "Claude Opus Latest"
        case .openAIGPTLatest: "GPT Latest"
        case .openAIGPTMiniLatest: "GPT Mini Latest"
        case .deepSeekR1: "DeepSeek R1"
        case .deepSeekV32: "DeepSeek V3.2"
        }
    }

    var providerName: String {
        switch self {
        case .bigPickle, .deepSeekV4FlashFree, .mimoV25Free, .nemotron3SuperFree:
            "OpenCode Zen"
        case .gemini31FlashLite, .gemini31ProPreviewCustomTools, .gemini35Flash, .gemma426bA4BIT, .gemma431bIT:
            "Google"
        case .claudeHaikuLatest, .claudeSonnetLatest, .claudeOpusLatest:
            "OpenRouter Anthropic"
        case .openAIGPTLatest, .openAIGPTMiniLatest:
            "OpenRouter OpenAI"
        case .deepSeekR1, .deepSeekV32:
            "OpenRouter DeepSeek"
        }
    }

    var modelIdentifier: String {
        switch self {
        case .bigPickle:
            "opencode/big-pickle"
        case .deepSeekV4FlashFree:
            "opencode/deepseek-v4-flash-free"
        case .mimoV25Free:
            "opencode/mimo-v2.5-free"
        case .nemotron3SuperFree:
            "opencode/nemotron-3-super-free"
        case .gemini31FlashLite:
            "google/gemini-3.1-flash-lite"
        case .gemini31ProPreviewCustomTools:
            "google/gemini-3.1-pro-preview-customtools"
        case .gemini35Flash:
            "google/gemini-3.5-flash"
        case .gemma426bA4BIT:
            "google/gemma-4-26b-a4b-it"
        case .gemma431bIT:
            "google/gemma-4-31b-it"
        case .claudeHaikuLatest:
            "openrouter/~anthropic/claude-haiku-latest"
        case .claudeSonnetLatest:
            "openrouter/~anthropic/claude-sonnet-latest"
        case .claudeOpusLatest:
            "openrouter/~anthropic/claude-opus-latest"
        case .openAIGPTLatest:
            "openrouter/~openai/gpt-latest"
        case .openAIGPTMiniLatest:
            "openrouter/~openai/gpt-mini-latest"
        case .deepSeekR1:
            "openrouter/deepseek/deepseek-r1"
        case .deepSeekV32:
            "openrouter/deepseek/deepseek-v3.2"
        }
    }

    static var opencodeZenCases: [OpenCodeModelPreset] {
        [.bigPickle, .deepSeekV4FlashFree, .mimoV25Free, .nemotron3SuperFree]
    }

    static var googleCases: [OpenCodeModelPreset] {
        [.gemini31FlashLite, .gemini31ProPreviewCustomTools, .gemini35Flash, .gemma426bA4BIT, .gemma431bIT]
    }

    static var openRouterCases: [OpenCodeModelPreset] {
        [.claudeHaikuLatest, .claudeSonnetLatest, .claudeOpusLatest, .openAIGPTLatest, .openAIGPTMiniLatest, .deepSeekR1, .deepSeekV32]
    }
}

enum OpenCodeVariantPreset: String, CaseIterable, Identifiable {
    case automatic
    case minimal
    case low
    case medium
    case high
    case max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Auto"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .max: "Max"
        }
    }

    var argumentValue: String? {
        self == .automatic ? nil : rawValue
    }
}

enum MessageRole {
    case user
    case agent(String)
    case system
}

struct ChatAttachment: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var path: String
    var filename: String
    var mimeType: String?

    init(id: UUID = UUID(), path: String, filename: String, mimeType: String? = nil) {
        self.id = id
        self.path = path
        self.filename = filename
        self.mimeType = mimeType
    }

    var url: URL {
        URL(fileURLWithPath: path)
    }

    var isImage: Bool {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "gif", "tiff", "bmp"]
        if let mimeType, mimeType.hasPrefix("image/") {
            return true
        }
        return imageExtensions.contains(url.pathExtension.lowercased())
    }
}

struct ChatMessage: Identifiable {
    let id: UUID
    let role: MessageRole
    var text: String
    var attachments: [ChatAttachment]
    let createdAt: Date

    init(id: UUID = UUID(), role: MessageRole, text: String, attachments: [ChatAttachment] = [], createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
        self.createdAt = createdAt
    }
}

enum TranscriptStore {
    private struct StoredMessage: Codable {
        var id: UUID
        var role: String
        var agentID: String?
        var text: String
        var attachments: [ChatAttachment]?
        var createdAt: Date
    }

    static var transcriptURL: URL {
        RuntimePaths.applicationSupportDirectory
            .appendingPathComponent("transcript.json")
    }

    static func load() -> [ChatMessage] {
        guard let data = try? Data(contentsOf: transcriptURL),
              let stored = try? decoder.decode([StoredMessage].self, from: data) else {
            return []
        }
        let messages = stored.compactMap { item -> ChatMessage? in
            let role: MessageRole
            switch item.role {
            case "user":
                role = .user
            case "system":
                role = .system
            case "agent":
                role = .agent(item.agentID ?? "agent1")
            default:
                return nil
            }
            return ChatMessage(id: item.id, role: role, text: item.text, attachments: item.attachments ?? [], createdAt: item.createdAt)
        }
        return dedupeConsecutiveUserMessages(messages)
    }

    static func save(_ messages: [ChatMessage]) {
        let stored = messages.map { message in
            switch message.role {
            case .user:
                StoredMessage(id: message.id, role: "user", agentID: nil, text: message.text, attachments: message.attachments, createdAt: message.createdAt)
            case .system:
                StoredMessage(id: message.id, role: "system", agentID: nil, text: message.text, attachments: message.attachments, createdAt: message.createdAt)
            case .agent(let agentID):
                StoredMessage(id: message.id, role: "agent", agentID: agentID, text: message.text, attachments: message.attachments, createdAt: message.createdAt)
            }
        }

        do {
            try FileManager.default.createDirectory(at: transcriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(stored)
            try data.write(to: transcriptURL, options: [.atomic])
        } catch {
            // Transcript persistence is a convenience layer; chat routing still works without it.
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: transcriptURL)
    }

    private static func dedupeConsecutiveUserMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        var result: [ChatMessage] = []
        for message in messages {
            if case .user = message.role,
               let previous = result.last,
               case .user = previous.role,
               normalizedUserText(previous.text) == normalizedUserText(message.text),
               attachmentFingerprint(previous.attachments) == attachmentFingerprint(message.attachments) {
                continue
            }
            result.append(message)
        }
        return result
    }

    private static func normalizedUserText(_ text: String) -> String {
        var trimmed = text
            .replacingOccurrences(
                of: #"(?s)\n?\s*---\s*\n\[Group context\].*?\[/Group context\]\s*"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?s)\n?\s*<!--\s*FloatScope group context.*?-->\s*"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let pairs: [(Character, Character)] = [
            ("\"", "\""),
            ("“", "”"),
            ("「", "」"),
            ("『", "』")
        ]
        for (open, close) in pairs where trimmed.first == open && trimmed.last == close {
            trimmed.removeFirst()
            trimmed.removeLast()
            return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func attachmentFingerprint(_ attachments: [ChatAttachment]) -> String {
        attachments
            .map { attachment in
                let stablePath = URL(fileURLWithPath: attachment.path).standardizedFileURL.path
                return "\(stablePath)|\(attachment.filename)|\(attachment.mimeType ?? "")"
            }
            .sorted()
            .joined(separator: "\n")
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct SettingsKeys {
    static let selectedAgent = "FloatScope.selectedAgent"
    static let selectedAgentID = "FloatScope.selectedAgentID"
    static let defaultAgent = "FloatScope.defaultAgent"
    static let codexPath = "FloatScope.codexPath"
    static let opencodePath = "FloatScope.opencodePath"
    static let conversationRoot = "FloatScope.conversationRoot"
    static let launchAtLogin = "FloatScope.launchAtLogin"
    static let capsuleOpacity = "FloatScope.capsuleOpacity"
    static let watchDefaultInterval = "FloatScope.watchDefaultInterval"
    static let windowFrame = "FloatScope.windowFrame"
    static let modelPreset = "FloatScope.modelPreset"
    static let codexModelPreset = "FloatScope.codexModelPreset"
    static let secondaryModelPreset = "FloatScope.secondaryModelPreset"
    static let codexEffortPreset = "FloatScope.codexEffortPreset"
    static let secondaryVariantPreset = "FloatScope.secondaryVariantPreset"
    static let primaryDisplayName = "FloatScope.primaryDisplayName"
    static let secondaryDisplayName = "FloatScope.secondaryDisplayName"
    static let userColor = "FloatScope.userColor"
    static let primaryColor = "FloatScope.primaryColor"
    static let secondaryColor = "FloatScope.secondaryColor"
    static let systemColor = "FloatScope.systemColor"
    static let showSystemMessages = "FloatScope.showSystemMessages"
    static let toggleShortcut = "FloatScope.toggleShortcut"
    static let screenReplayCacheEnabled = "FloatScope.screenReplayCacheEnabled"
    static let appLanguage = "FloatScope.appLanguage"
    static let autoCollapseAfterReply = "FloatScope.autoCollapseAfterReply"
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case chinese

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .english: "English"
        case .chinese: "中文"
        }
    }

    var resolvedIdentifier: String {
        switch self {
        case .english:
            "en"
        case .chinese:
            "zh"
        case .system:
            Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en"
        }
    }

    var isChinese: Bool {
        resolvedIdentifier == "zh"
    }
}

enum L10n {
    static func text(_ key: Key, language: AppLanguage = FloatScopeSettings().appLanguage) -> String {
        language.isChinese ? key.zh : key.en
    }

    enum Key {
        case addAttachment
        case editLongText
        case send
        case modelPickerHelp
        case history
        case expand
        case collapse
        case screenCapture
        case agentPickerHelp
        case group
        case configuredInSettings
        case agentFallback
        case effort
        case variant
        case conversationHistory
        case refresh
        case noHistoryTitle
        case noHistoryDescription
        case delete
        case close
        case messages
        case collapseEditor
        case settingsTitle
        case agents
        case userColor
        case addAgent
        case agentTitle
        case agent1Model
        case agent1Effort
        case agent2Model
        case agent2Variant
        case conversationProject
        case toggleShortcut
        case launchAtLogin
        case showSystemMessages
        case screenReplayCache
        case opacity
        case watchInterval
        case autoCollapse
        case seconds
        case cancel
        case apply
        case removeAgent
        case id
        case name
        case kind
        case color
        case executable
        case model
        case appLanguage
        case openFloatScope
        case resetPosition
        case conversationHistoryMenu
        case newConversation
        case compressContext
        case toggleScreenWatch
        case settings
        case quit
        case draft
        case rollback
        case ready
        case newConversationStarted
        case screenWatchStopped
        case screenWatchStarted
        case switched
        case unknownAgent
        case capturedScreen
        case watchCaptureSent
        case watchObservationPrompt
        case attachmentPrompt
        case currentMessageAttachments
        case earlierGroupContextTruncated
        case contextLimitWarningTitle
        case contextLimitWarningBody
        case contextCompressionPrompt
        case contextCompressionRequested
        case sessionStarted

        var en: String {
            switch self {
            case .addAttachment: "Add image or file"
            case .editLongText: "Edit long text"
            case .send: "Send"
            case .modelPickerHelp: "Choose model"
            case .history: "History"
            case .expand: "Expand"
            case .collapse: "Collapse"
            case .screenCapture: "Capture screen"
            case .agentPickerHelp: "Choose agent"
            case .group: "Group"
            case .configuredInSettings: "Configured in Settings"
            case .agentFallback: "Agent"
            case .effort: "Effort"
            case .variant: "Variant"
            case .conversationHistory: "Conversation History"
            case .refresh: "Refresh"
            case .noHistoryTitle: "No History"
            case .noHistoryDescription: "No FloatScope project conversations were found."
            case .delete: "Delete"
            case .close: "Close"
            case .messages: "Messages"
            case .collapseEditor: "Collapse editor"
            case .settingsTitle: "FloatScope Settings"
            case .agents: "Agents"
            case .userColor: "User Color"
            case .addAgent: "Add Agent"
            case .agentTitle: "Agent"
            case .agent1Model: "Agent 1 Model"
            case .agent1Effort: "Agent 1 Effort"
            case .agent2Model: "Agent 2 Model"
            case .agent2Variant: "Agent 2 Variant"
            case .conversationProject: "Conversation Project"
            case .toggleShortcut: "Toggle Shortcut"
            case .launchAtLogin: "Launch at Login"
            case .showSystemMessages: "Show System Messages"
            case .screenReplayCache: "Screen Replay Cache"
            case .opacity: "Opacity"
            case .watchInterval: "Watch Interval"
            case .autoCollapse: "Auto Collapse"
            case .seconds: "Seconds"
            case .cancel: "Cancel"
            case .apply: "Apply"
            case .removeAgent: "Remove Agent"
            case .id: "ID"
            case .name: "Name"
            case .kind: "Kind"
            case .color: "Color"
            case .executable: "Executable"
            case .model: "Model"
            case .appLanguage: "Language"
            case .openFloatScope: "Open FloatScope"
            case .resetPosition: "Reset Position"
            case .conversationHistoryMenu: "Conversation History..."
            case .newConversation: "New Conversation"
            case .compressContext: "Compress Context"
            case .toggleScreenWatch: "Toggle Screen Watch"
            case .settings: "Settings..."
            case .quit: "Quit FloatScope"
            case .draft: "Draft"
            case .rollback: "Rollback"
            case .ready: "FloatScope ready."
            case .newConversationStarted: "Started a new FloatScope conversation."
            case .screenWatchStopped: "Screen watch stopped."
            case .screenWatchStarted: "Screen watch started."
            case .switched: "Switched."
            case .unknownAgent: "Unknown agent"
            case .capturedScreen: "Captured screen"
            case .watchCaptureSent: "Watch capture sent."
            case .watchObservationPrompt: "Scheduled screen capture: please give a brief observation from this screenshot."
            case .attachmentPrompt: "Please review these attachments."
            case .currentMessageAttachments: "Current message attachments"
            case .earlierGroupContextTruncated: "earlier group context truncated"
            case .contextLimitWarningTitle: "FloatScope context is getting long"
            case .contextLimitWarningBody: "Consider compressing the current conversation from the menu bar."
            case .contextCompressionPrompt: "Please summarize the current conversation into a compact continuation note. Keep durable facts, active tasks, decisions, open bugs, and the latest user preferences. Do not restate hidden group context."
            case .contextCompressionRequested: "Context compression requested."
            case .sessionStarted: "session started."
            }
        }

        var zh: String {
            switch self {
            case .addAttachment: "添加图像或文件"
            case .editLongText: "编辑长文本"
            case .send: "发送"
            case .modelPickerHelp: "选择模型"
            case .history: "聊天记录"
            case .expand: "展开"
            case .collapse: "收回"
            case .screenCapture: "截屏"
            case .agentPickerHelp: "选择聊天对象"
            case .group: "群聊"
            case .configuredInSettings: "在设置中配置"
            case .agentFallback: "Agent"
            case .effort: "智能等级"
            case .variant: "模式"
            case .conversationHistory: "聊天记录"
            case .refresh: "刷新"
            case .noHistoryTitle: "暂无记录"
            case .noHistoryDescription: "没有找到 FloatScope 项目的对话。"
            case .delete: "删除"
            case .close: "关闭"
            case .messages: "条消息"
            case .collapseEditor: "收起编辑器"
            case .settingsTitle: "FloatScope 设置"
            case .agents: "Agent"
            case .userColor: "用户颜色"
            case .addAgent: "添加 Agent"
            case .agentTitle: "Agent"
            case .agent1Model: "Agent 1 模型"
            case .agent1Effort: "Agent 1 智能等级"
            case .agent2Model: "Agent 2 模型"
            case .agent2Variant: "Agent 2 模式"
            case .conversationProject: "对话项目"
            case .toggleShortcut: "显示/隐藏快捷键"
            case .launchAtLogin: "开机启动"
            case .showSystemMessages: "显示系统消息"
            case .screenReplayCache: "屏幕回放缓存"
            case .opacity: "透明度"
            case .watchInterval: "读屏间隔"
            case .autoCollapse: "自动收回"
            case .seconds: "秒"
            case .cancel: "取消"
            case .apply: "应用"
            case .removeAgent: "移除 Agent"
            case .id: "ID"
            case .name: "名称"
            case .kind: "类型"
            case .color: "颜色"
            case .executable: "可执行文件"
            case .model: "模型"
            case .appLanguage: "语言"
            case .openFloatScope: "打开 FloatScope"
            case .resetPosition: "重置位置"
            case .conversationHistoryMenu: "聊天记录..."
            case .newConversation: "新建对话"
            case .compressContext: "压缩上下文"
            case .toggleScreenWatch: "切换定时读屏"
            case .settings: "设置..."
            case .quit: "退出 FloatScope"
            case .draft: "草稿"
            case .rollback: "回退"
            case .ready: "FloatScope 已就绪。"
            case .newConversationStarted: "已开启新的 FloatScope 对话。"
            case .screenWatchStopped: "已停止读屏。"
            case .screenWatchStarted: "已开始读屏。"
            case .switched: "已切换。"
            case .unknownAgent: "未知 Agent"
            case .capturedScreen: "已截屏"
            case .watchCaptureSent: "已发送读屏截图。"
            case .watchObservationPrompt: "定时读屏：请根据这张屏幕截图给出简短观察。"
            case .attachmentPrompt: "请看这些附件。"
            case .currentMessageAttachments: "当前消息附件"
            case .earlierGroupContextTruncated: "更早的群聊上下文已截断"
            case .contextLimitWarningTitle: "FloatScope 上下文变长了"
            case .contextLimitWarningBody: "可以从状态栏菜单压缩当前对话。"
            case .contextCompressionPrompt: "请把当前对话总结成一份紧凑的续聊上下文。保留长期事实、当前任务、已做决定、未解决问题和最新用户偏好。不要复述隐藏的群聊上下文。"
            case .contextCompressionRequested: "已请求压缩上下文。"
            case .sessionStarted: "会话已启动。"
            }
        }
    }
}

struct FloatScopeSettings {
    var defaultAgent: AgentID {
        get { AgentID(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.defaultAgent) ?? "") ?? .primary }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.defaultAgent) }
    }

    var codexPath: String {
        get { UserDefaults.standard.string(forKey: SettingsKeys.codexPath) ?? AgentHubConfigStore.agent(at: 0).executablePath }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.codexPath) }
    }

    var opencodePath: String {
        get { UserDefaults.standard.string(forKey: SettingsKeys.opencodePath) ?? AgentHubConfigStore.agent(at: 1).executablePath }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.opencodePath) }
    }

    var primaryDisplayName: String {
        get {
            let stored = UserDefaults.standard.string(forKey: SettingsKeys.primaryDisplayName)
            return stored ?? AgentHubConfigStore.agent(at: 0).displayName
        }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.primaryDisplayName) }
    }

    var secondaryDisplayName: String {
        get {
            let stored = UserDefaults.standard.string(forKey: SettingsKeys.secondaryDisplayName)
            return stored ?? AgentHubConfigStore.agent(at: 1).displayName
        }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.secondaryDisplayName) }
    }

    var userColorHex: String {
        get { UserDefaults.standard.string(forKey: SettingsKeys.userColor) ?? "#4C8DFF" }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.userColor) }
    }

    var primaryColorHex: String {
        get { UserDefaults.standard.string(forKey: SettingsKeys.primaryColor) ?? AgentHubConfigStore.agent(at: 0).color }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.primaryColor) }
    }

    var secondaryColorHex: String {
        get { UserDefaults.standard.string(forKey: SettingsKeys.secondaryColor) ?? AgentHubConfigStore.agent(at: 1).color }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.secondaryColor) }
    }

    var systemColorHex: String {
        get { UserDefaults.standard.string(forKey: SettingsKeys.systemColor) ?? "#8E8E93" }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.systemColor) }
    }

    var visuals: AgentVisualConfig {
        AgentVisualConfig(
            agent1Name: primaryDisplayName,
            agent2Name: secondaryDisplayName,
            userColorHex: userColorHex,
            agent1ColorHex: primaryColorHex,
            agent2ColorHex: secondaryColorHex,
            systemColorHex: systemColorHex
        )
    }

    var conversationRoot: String {
        get {
            UserDefaults.standard.string(forKey: SettingsKeys.conversationRoot)
                ?? AgentHubConfigStore.load().conversationRoot
        }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.conversationRoot) }
    }

    var launchAtLogin: Bool {
        get { UserDefaults.standard.bool(forKey: SettingsKeys.launchAtLogin) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.launchAtLogin) }
    }

    var capsuleOpacity: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: SettingsKeys.capsuleOpacity)
            return stored == 0 ? 0.96 : CGFloat(stored)
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: SettingsKeys.capsuleOpacity) }
    }

    var watchDefaultInterval: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: SettingsKeys.watchDefaultInterval)
            return stored == 0 ? 60 : stored
        }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.watchDefaultInterval) }
    }

    var autoCollapseAfterReply: TimeInterval {
        get {
            let stored = UserDefaults.standard.object(forKey: SettingsKeys.autoCollapseAfterReply) as? Double
            return stored ?? 8
        }
        set { UserDefaults.standard.set(max(0, newValue), forKey: SettingsKeys.autoCollapseAfterReply) }
    }

    var showSystemMessages: Bool {
        get { UserDefaults.standard.bool(forKey: SettingsKeys.showSystemMessages) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.showSystemMessages) }
    }

    var screenReplayCacheEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: SettingsKeys.screenReplayCacheEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.screenReplayCacheEnabled) }
    }

    var toggleShortcut: String {
        get { UserDefaults.standard.string(forKey: SettingsKeys.toggleShortcut) ?? "Option+Space" }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.toggleShortcut) }
    }

    var appLanguage: AppLanguage {
        get {
            AppLanguage(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.appLanguage) ?? "") ?? .system
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.appLanguage) }
    }

    var codexModelPreset: CodexModelPreset {
        get {
            if let stored = UserDefaults.standard.string(forKey: SettingsKeys.codexModelPreset),
               let preset = CodexModelPreset(rawValue: stored) {
                return preset
            }
            if let legacy = UserDefaults.standard.string(forKey: SettingsKeys.modelPreset),
               let preset = CodexModelPreset(rawValue: legacy) {
                return preset
            }
            return .gpt55
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.codexModelPreset) }
    }

    var codexEffortPreset: ReasoningEffortPreset {
        get {
            let stored = UserDefaults.standard.string(forKey: SettingsKeys.codexEffortPreset) ?? ""
            if stored == "minimal" || stored == "none" {
                return .low
            }
            return ReasoningEffortPreset(rawValue: stored) ?? .medium
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.codexEffortPreset) }
    }

    var secondaryModelPreset: OpenCodeModelPreset {
        get {
            OpenCodeModelPreset(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.secondaryModelPreset) ?? "")
                ?? .deepSeekV4FlashFree
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.secondaryModelPreset) }
    }

    var secondaryVariantPreset: OpenCodeVariantPreset {
        get {
            OpenCodeVariantPreset(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.secondaryVariantPreset) ?? "")
                ?? .automatic
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.secondaryVariantPreset) }
    }
}

extension Color {
    init(hex: String) {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}
