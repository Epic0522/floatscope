import Foundation
import SwiftUI

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
    var model: String?
    var effort: String?
    var variant: String?
    var models: [String]?
    var efforts: [String]?
    var variants: [String]?
}

enum AgentHubConfigStore {
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("FloatScope")
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
            if normalized.kind == "codex-app-server" || index == 0 {
                normalized.efforts = ReasoningEffortPreset.allCases.map(\.rawValue)
                if normalized.effort == "minimal" || normalized.effort == "none" || normalized.effort == nil {
                    normalized.effort = "low"
                }
            }
            return normalized
        }
        return migrated
    }

    static var defaultConfig: AgentHubConfig {
        AgentHubConfig(
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
                    model: CodexModelPreset.gpt54Mini.codexModel,
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
}

enum AgentID: String, CaseIterable, Identifiable {
    case agent1
    case agent2
    case auto

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .agent1: "Agent 1"
        case .agent2: "Agent 2"
        case .auto: "Auto"
        }
    }
}

enum ConcreteAgentID: String, CaseIterable, Identifiable {
    case agent1
    case agent2

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .agent1: "Agent 1"
        case .agent2: "Agent 2"
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
    var agent1Color: Color { Color(hex: agent1ColorHex) }
    var agent2Color: Color { Color(hex: agent2ColorHex) }
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
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("FloatScope")
            .appendingPathComponent("transcript.json")
    }

    static func load() -> [ChatMessage] {
        guard let data = try? Data(contentsOf: transcriptURL),
              let stored = try? decoder.decode([StoredMessage].self, from: data) else {
            return []
        }
        return stored.compactMap { item in
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
    static let agent2ModelPreset = "FloatScope.agent2ModelPreset"
    static let codexEffortPreset = "FloatScope.codexEffortPreset"
    static let agent2VariantPreset = "FloatScope.agent2VariantPreset"
    static let agent1DisplayName = "FloatScope.agent1DisplayName"
    static let agent2DisplayName = "FloatScope.agent2DisplayName"
    static let userColor = "FloatScope.userColor"
    static let agent1Color = "FloatScope.agent1Color"
    static let agent2Color = "FloatScope.agent2Color"
    static let systemColor = "FloatScope.systemColor"
    static let showSystemMessages = "FloatScope.showSystemMessages"
    static let toggleShortcut = "FloatScope.toggleShortcut"
    static let screenReplayCacheEnabled = "FloatScope.screenReplayCacheEnabled"
}

struct FloatScopeSettings {
    var defaultAgent: AgentID {
        get { AgentID(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.defaultAgent) ?? "") ?? .agent1 }
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

    var agent1DisplayName: String {
        get {
            let stored = UserDefaults.standard.string(forKey: SettingsKeys.agent1DisplayName)
            return stored ?? AgentHubConfigStore.agent(at: 0).displayName
        }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.agent1DisplayName) }
    }

    var agent2DisplayName: String {
        get {
            let stored = UserDefaults.standard.string(forKey: SettingsKeys.agent2DisplayName)
            return stored ?? AgentHubConfigStore.agent(at: 1).displayName
        }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.agent2DisplayName) }
    }

    var userColorHex: String {
        get { UserDefaults.standard.string(forKey: SettingsKeys.userColor) ?? "#4C8DFF" }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.userColor) }
    }

    var agent1ColorHex: String {
        get { UserDefaults.standard.string(forKey: SettingsKeys.agent1Color) ?? AgentHubConfigStore.agent(at: 0).color }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.agent1Color) }
    }

    var agent2ColorHex: String {
        get { UserDefaults.standard.string(forKey: SettingsKeys.agent2Color) ?? AgentHubConfigStore.agent(at: 1).color }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.agent2Color) }
    }

    var systemColorHex: String {
        get { UserDefaults.standard.string(forKey: SettingsKeys.systemColor) ?? "#8E8E93" }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.systemColor) }
    }

    var visuals: AgentVisualConfig {
        AgentVisualConfig(
            agent1Name: agent1DisplayName,
            agent2Name: agent2DisplayName,
            userColorHex: userColorHex,
            agent1ColorHex: agent1ColorHex,
            agent2ColorHex: agent2ColorHex,
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

    var agent2ModelPreset: OpenCodeModelPreset {
        get {
            OpenCodeModelPreset(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.agent2ModelPreset) ?? "")
                ?? .deepSeekV4FlashFree
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.agent2ModelPreset) }
    }

    var agent2VariantPreset: OpenCodeVariantPreset {
        get {
            OpenCodeVariantPreset(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.agent2VariantPreset) ?? "")
                ?? .automatic
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.agent2VariantPreset) }
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
