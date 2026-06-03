import Foundation

enum AgentBridgeEvent {
    case started(String)
    case streamDelta(String, String)
    case completed(String)
    case failed(String, String)
}

private protocol CodexSessionControlling: AnyObject {
    var agentID: String { get }
    var onEvent: ((AgentBridgeEvent) -> Void)? { get set }

    func start()
    func send(message: String, attachments: [URL], modelPreset: CodexModelPreset, effortPreset: ReasoningEffortPreset)
    func stop()
    func resetConversation()
    func rollbackLastTurns(_ count: Int)
    func selectConversation(threadID: String?, title: String)
}

final class AgentBridge: @unchecked Sendable {
    var onEvent: ((AgentBridgeEvent) -> Void)?

    private var codex: CodexSessionControlling?
    private var opencode: OpencodeRunSession?
    private var genericSessions: [String: GenericCLISession] = [:]
    private var configs: [String: AgentRuntimeConfig] = [:]
    private var codexUsesCLI = false

    func configure(config: AgentHubConfig) {
        stopAll()
        genericSessions.removeAll()
        configs = [:]
        codexUsesCLI = false
        for agent in config.agents {
            configs[agent.id] = agent
        }

        let root = URL(fileURLWithPath: config.conversationRoot).standardizedFileURL.path
        let visibleRoot = CodexWorkspaceResolver.visibleWorkspaceRoot(preferredRoot: root)
        CodexHistoryVisibilityRegistrar.registerWorkspace(workspaceRoot: visibleRoot)
        OpenCodeHistoryVisibilityRegistrar.registerProject(workspaceRoot: root)

        for (index, agent) in config.agents.enumerated() {
            switch agent.kind {
            case "codex-app-server" where index == 0:
                let session = CodexAppServerSession(agentID: agent.id, executablePath: agent.executablePath, appBundlePath: agent.appBundlePath, context: ConversationContext(rootPath: visibleRoot))
                session.onEvent = { [weak self] event in self?.onEvent?(event) }
                codex = session
            case "codex-cli-resume" where index == 0:
                codexUsesCLI = true
                let session = CodexCLISession(agentID: agent.id, executablePath: agent.executablePath, context: ConversationContext(rootPath: visibleRoot))
                session.onEvent = { [weak self] event in self?.onEvent?(event) }
                codex = session
            case "opencode-run" where index == 1:
                let session = OpencodeRunSession(agentID: agent.id, executablePath: agent.executablePath, appBundlePath: agent.appBundlePath, context: ConversationContext(rootPath: root))
                session.onEvent = { [weak self] event in self?.onEvent?(event) }
                opencode = session
            default:
                let session = GenericCLISession(config: agent, context: ConversationContext(rootPath: root))
                session.onEvent = { [weak self] event in self?.onEvent?(event) }
                genericSessions[agent.id] = session
            }
        }
    }

    func configure(codexPath: String, opencodePath: String, conversationRoot: String) {
        codex?.stop()
        opencode?.stop()
        codexUsesCLI = false

        let opencodeRoot = URL(fileURLWithPath: conversationRoot).standardizedFileURL.path
        let visibleRoot = CodexWorkspaceResolver.visibleWorkspaceRoot(preferredRoot: conversationRoot)
        let opencodeContext = ConversationContext(rootPath: opencodeRoot)
        let codexContext = ConversationContext(rootPath: visibleRoot)
        CodexHistoryVisibilityRegistrar.registerWorkspace(workspaceRoot: visibleRoot)
        OpenCodeHistoryVisibilityRegistrar.registerProject(workspaceRoot: opencodeRoot)
        let codex = CodexAppServerSession(agentID: "agent1", executablePath: codexPath, appBundlePath: nil, context: codexContext)
        let opencode = OpencodeRunSession(agentID: "agent2", executablePath: opencodePath, appBundlePath: nil, context: opencodeContext)

        codex.onEvent = { [weak self] event in self?.onEvent?(event) }
        opencode.onEvent = { [weak self] event in self?.onEvent?(event) }

        self.codex = codex
        self.opencode = opencode
    }

    func startAll() {
        // Agent processes are launched lazily on first send so FloatScope can idle
        // without pulling Codex/OpenCode apps into the foreground.
    }

    func send(
        agent: String,
        message: String,
        attachments: [URL] = [],
        codexModelPreset: CodexModelPreset,
        codexEffortPreset: ReasoningEffortPreset,
        secondaryModelPreset: OpenCodeModelPreset,
        secondaryVariantPreset: OpenCodeVariantPreset
    ) {
        if agent == codex?.agentID {
            codex?.send(message: message, attachments: attachments, modelPreset: codexModelPreset, effortPreset: codexEffortPreset)
        } else if agent == opencode?.agentID {
            opencode?.send(message: message, attachments: attachments, modelPreset: secondaryModelPreset, variantPreset: secondaryVariantPreset)
        } else {
            genericSessions[agent]?.send(message: message, attachments: attachments)
        }
    }

    func rollback(agents: [String], numTurns: Int) {
        guard numTurns > 0 else { return }
        for agent in agents {
            if agent == codex?.agentID {
                codex?.rollbackLastTurns(numTurns)
            } else if agent == opencode?.agentID {
                opencode?.rollbackLastTurns(numTurns)
            }
        }
    }

    func stopAll() {
        codex?.stop()
        opencode?.stop()
        genericSessions.values.forEach { $0.stop() }
    }

    func startNewConversation(group: Bool = false) {
        ConversationContext.resetActiveTitle(prefix: titlePrefix(group: group))
        codex?.resetConversation()
        opencode?.resetConversation()
        genericSessions.values.forEach { $0.resetConversation() }
    }

    func prepareGroupConversationIfNeeded() {
        let prefix = titlePrefix(group: true) ?? "群聊 "
        guard ConversationContext.activeTitle?.hasPrefix(prefix) != true else { return }
        startNewConversation(group: true)
    }

    func selectConversation(_ entry: ConversationHistoryEntry) {
        ConversationContext.setActiveTitle(entry.title)
        codex?.selectConversation(threadID: entry.codexThreadID, title: entry.title)
        opencode?.selectConversation(sessionID: entry.opencodeSessionID, title: entry.title)
        genericSessions.values.forEach { $0.resetConversation() }
    }

    private func titlePrefix(group: Bool) -> String? {
        var parts: [String] = []
        if group {
            parts.append("群聊")
        }
        if codexUsesCLI {
            parts.append("CLI")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ") + " "
    }
}

private struct NativeSessionKeys {
    static let codexThreadId = "FloatScope.codexThreadId"
    static let codexThreadRoot = "FloatScope.codexThreadRoot"
    static let codexThreadTitle = "FloatScope.codexThreadTitle"
    static let opencodeSessionId = "FloatScope.opencodeSessionId"
    static let opencodeSessionRoot = "FloatScope.opencodeSessionRoot"
    static let opencodeSessionTitle = "FloatScope.opencodeSessionTitle"
    static let activeConversationTitle = "FloatScope.activeConversationTitle"
}

private struct ConversationContext: Sendable {
    let rootPath: String

    var title: String {
        if let existing = UserDefaults.standard.string(forKey: NativeSessionKeys.activeConversationTitle) {
            return existing
        }
        let title = Self.makeTimestampTitle()
        UserDefaults.standard.set(title, forKey: NativeSessionKeys.activeConversationTitle)
        return title
    }

    func ensureRoot() throws {
        try FileManager.default.createDirectory(atPath: rootPath, withIntermediateDirectories: true)
    }

    func reset() {
        Self.resetActiveTitle()
    }

    static func setActiveTitle(_ title: String) {
        UserDefaults.standard.set(title, forKey: NativeSessionKeys.activeConversationTitle)
    }

    static var activeTitle: String? {
        UserDefaults.standard.string(forKey: NativeSessionKeys.activeConversationTitle)
    }

    static func resetActiveTitle(prefix: String? = nil) {
        UserDefaults.standard.set(makeTimestampTitle(prefix: prefix), forKey: NativeSessionKeys.activeConversationTitle)
    }

    private static func makeTimestampTitle(prefix: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return (prefix ?? "") + formatter.string(from: Date())
    }
}

private enum CodexWorkspaceResolver {
    static func visibleWorkspaceRoot(preferredRoot: String) -> String {
        let normalizedPreferred = normalized(preferredRoot)
        let savedRoots = savedWorkspaceRoots()

        if let containingRoot = savedRoots
            .filter({ contains(root: $0, path: normalizedPreferred) })
            .max(by: { $0.count < $1.count }) {
            return containingRoot
        }

        if let floatScopeRoot = savedRoots.first(where: { URL(fileURLWithPath: $0).lastPathComponent == "floatscope" }) {
            return floatScopeRoot
        }

        return normalizedPreferred
    }

    private static func savedWorkspaceRoots() -> [String] {
        let stateURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent(".codex-global-state.json")

        guard let data = try? Data(contentsOf: stateURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["electron-saved-workspace-roots"] as? [String] else {
            return []
        }

        return roots.map(normalized)
    }

    private static func contains(root: String, path: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

private enum AgentApplicationLauncher {
    static func openIfConfigured(_ rawPath: String?) {
        guard let rawPath,
              !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let path = NSString(string: rawPath).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
    }
}

private final class CodexAppServerSession: CodexSessionControlling, @unchecked Sendable {
    var onEvent: ((AgentBridgeEvent) -> Void)?
    let agentID: String

    private let executablePath: String
    private let appBundlePath: String?
    private let context: ConversationContext
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputBuffer = Data()
    private var nextRequestID = 1
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var threadID: String?
    private var threadLoaded = false
    private var isStopping = false
    private var modelPreset: CodexModelPreset = .gpt55
    private var effortPreset: ReasoningEffortPreset = .medium
    private var activeTurnToken = 0
    private var awaitingFirstTurnOutput = false
    private let queue = DispatchQueue(label: "FloatScope.CodexAppServerSession")

    init(agentID: String, executablePath: String, appBundlePath: String?, context: ConversationContext) {
        self.agentID = agentID
        self.executablePath = executablePath
        self.appBundlePath = appBundlePath
        self.context = context
        let defaults = UserDefaults.standard
        if defaults.string(forKey: NativeSessionKeys.codexThreadRoot) == context.rootPath {
            self.threadID = defaults.string(forKey: NativeSessionKeys.codexThreadId)
            if let threadID {
                CodexHistoryVisibilityRegistrar.register(threadID: threadID, workspaceRoot: context.rootPath)
                CodexHistoryVisibilityRegistrar.registerSoon(threadID: threadID, workspaceRoot: context.rootPath)
            }
        } else {
            defaults.removeObject(forKey: NativeSessionKeys.codexThreadId)
            defaults.removeObject(forKey: NativeSessionKeys.codexThreadRoot)
            defaults.removeObject(forKey: NativeSessionKeys.codexThreadTitle)
        }
    }

    func start() {
        queue.async { [weak self] in
            self?.startLocked()
        }
    }

    func send(message: String, attachments: [URL], modelPreset: CodexModelPreset, effortPreset: ReasoningEffortPreset) {
        queue.async { [weak self] in
            guard let self else { return }
            self.modelPreset = modelPreset
            self.effortPreset = effortPreset
            self.startLocked()
            self.ensureThreadLocked { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let threadID):
                    self.turnStartLocked(threadID: threadID, message: message, attachments: attachments)
                case .failure(let error):
                    self.onEvent?(.failed(agentID, error.localizedDescription))
                }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStopping = true
            self.inputPipe?.fileHandleForWriting.closeFile()
            self.process?.terminate()
            self.process = nil
            self.inputPipe = nil
            self.pending.removeAll()
        }
    }

    func resetConversation() {
        queue.async { [weak self] in
            guard let self else { return }
            self.threadID = nil
            self.threadLoaded = false
            UserDefaults.standard.removeObject(forKey: NativeSessionKeys.codexThreadId)
            UserDefaults.standard.removeObject(forKey: NativeSessionKeys.codexThreadRoot)
            UserDefaults.standard.removeObject(forKey: NativeSessionKeys.codexThreadTitle)
        }
    }

    func rollbackLastTurns(_ count: Int) {
        queue.async { [weak self] in
            guard let self, count > 0 else { return }
            self.startLocked()
            guard let threadID = self.threadID else { return }
            self.requestLocked(method: "thread/rollback", params: [
                "threadId": threadID,
                "numTurns": count
            ]) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.threadLoaded = true
                    CodexHistoryVisibilityRegistrar.register(threadID: threadID, workspaceRoot: self.context.rootPath)
                    CodexHistoryVisibilityRegistrar.registerSoon(threadID: threadID, workspaceRoot: self.context.rootPath)
                case .failure(let error):
                    self.onEvent?(.failed(self.agentID, "Unable to roll back Codex thread: \(error.localizedDescription)"))
                }
            }
        }
    }

    func selectConversation(threadID: String?, title: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.threadID = threadID
            self.threadLoaded = false
            if let threadID {
                UserDefaults.standard.set(threadID, forKey: NativeSessionKeys.codexThreadId)
                UserDefaults.standard.set(self.context.rootPath, forKey: NativeSessionKeys.codexThreadRoot)
                UserDefaults.standard.set(title, forKey: NativeSessionKeys.codexThreadTitle)
                CodexHistoryVisibilityRegistrar.register(threadID: threadID, workspaceRoot: self.context.rootPath)
            } else {
                UserDefaults.standard.removeObject(forKey: NativeSessionKeys.codexThreadId)
                UserDefaults.standard.removeObject(forKey: NativeSessionKeys.codexThreadRoot)
                UserDefaults.standard.removeObject(forKey: NativeSessionKeys.codexThreadTitle)
            }
        }
    }

    private func startLocked() {
        guard process == nil else { return }
        AgentApplicationLauncher.openIfConfigured(appBundlePath)
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            onEvent?(.failed(agentID, "Executable not found: \(executablePath)"))
            return
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        process.environment = ProcessInfo.processInfo.environment.merging([
            "NO_COLOR": "1"
        ]) { _, new in new }

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let session = self else { return }
            session.queue.async {
                session.handleOutputLocked(data)
            }
        }

        process.terminationHandler = { [weak self] terminated in
            guard let session = self else { return }
            session.queue.async {
                let message = "Codex app-server exited with status \(terminated.terminationStatus)"
                if !session.isStopping {
                    session.awaitingFirstTurnOutput = false
                    session.failPendingLocked(message)
                    session.onEvent?(.failed(session.agentID, message))
                }
                session.isStopping = false
                session.process = nil
                session.inputPipe = nil
                session.outputBuffer.removeAll(keepingCapacity: false)
            }
        }

        do {
            try process.run()
            isStopping = false
            self.process = process
            self.inputPipe = input
            initializeLocked()
        } catch {
            onEvent?(.failed(agentID, error.localizedDescription))
        }
    }

    private func initializeLocked() {
        requestLocked(method: "initialize", params: [
            "clientInfo": [
                "name": "FloatScope",
                "title": "FloatScope",
                "version": "0.1.0"
            ],
            "capabilities": [
                "experimentalApi": true,
                "requestAttestation": false,
                "optOutNotificationMethods": []
            ]
        ]) { [weak self] result in
            switch result {
            case .success:
                self?.onEvent?(.started(self?.agentID ?? "agent1"))
            case .failure(let error):
                self?.onEvent?(.failed(self?.agentID ?? "agent1", error.localizedDescription))
            }
        }
    }

    private func ensureThreadLocked(completion: @escaping (Result<String, Error>) -> Void) {
        if let threadID {
            if threadLoaded {
                CodexHistoryVisibilityRegistrar.register(threadID: threadID, workspaceRoot: context.rootPath)
                completion(.success(threadID))
                return
            }
            requestLocked(method: "thread/resume", params: [
                "threadId": threadID,
                "excludeTurns": true,
                "persistExtendedHistory": false
            ]) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.threadLoaded = true
                    CodexHistoryVisibilityRegistrar.register(threadID: threadID, workspaceRoot: self.context.rootPath)
                    completion(.success(threadID))
                case .failure:
                    self.threadID = nil
                    UserDefaults.standard.removeObject(forKey: NativeSessionKeys.codexThreadId)
                    UserDefaults.standard.removeObject(forKey: NativeSessionKeys.codexThreadRoot)
                    self.ensureThreadLocked(completion: completion)
                }
            }
            return
        }

        do {
            try context.ensureRoot()
        } catch {
            completion(.failure(error))
            return
        }

        let cwd = context.rootPath
        let title = context.title
        requestLocked(method: "thread/start", params: [
            "cwd": cwd,
            "model": modelPreset.codexModel,
            "threadSource": "user",
            "sessionStartSource": "startup",
            "experimentalRawEvents": false,
            "persistExtendedHistory": false
        ]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let object):
                if let thread = object["thread"] as? [String: Any],
                   let id = thread["id"] as? String {
                    self.setThreadIDLocked(id)
                    self.threadLoaded = true
                    self.setThreadNameLocked(threadID: id, title: title)
                    completion(.success(id))
                } else {
                    completion(.failure(BridgeError.invalidResponse("Missing thread id from thread/start.")))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func turnStartLocked(threadID: String, message: String, attachments: [URL]) {
        activeTurnToken += 1
        let turnToken = activeTurnToken
        awaitingFirstTurnOutput = true

        var input: [[String: Any]] = [
            [
                "type": "text",
                "text": message,
                "text_elements": []
            ]
        ]

        for attachment in attachments {
            if Self.isImageAttachment(attachment) {
                input.append([
                    "type": "localImage",
                    "path": attachment.path,
                    "detail": "high"
                ])
            } else {
                input.append([
                    "type": "text",
                    "text": "\n[Attachment: \(attachment.path)]",
                    "text_elements": []
                ])
            }
        }

        requestLocked(method: "turn/start", params: [
            "threadId": threadID,
            "model": modelPreset.codexModel,
            "effort": effortPreset.rawValue,
            "input": input
        ]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.scheduleTurnStartWatchdogLocked(token: turnToken)
            case .failure(let error):
                self.awaitingFirstTurnOutput = false
                self.onEvent?(.failed(self.agentID, error.localizedDescription))
            }
        }
    }

    private func scheduleTurnStartWatchdogLocked(token: Int) {
        queue.asyncAfter(deadline: .now() + 90) { [weak self] in
            guard let self,
                  self.activeTurnToken == token,
                  self.awaitingFirstTurnOutput else {
                return
            }
            self.awaitingFirstTurnOutput = false
            self.onEvent?(.failed(self.agentID, "Codex accepted the message but did not start a reply. Try sending again or start a new conversation."))
        }
    }

    private func requestLocked(method: String, params: Any?, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let id = nextRequestID
        nextRequestID += 1
        pending[id] = completion

        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method
        ]
        if let params {
            payload["params"] = params
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard let line = String(data: data, encoding: .utf8)?.appending("\n"),
                  let lineData = line.data(using: .utf8) else {
                throw BridgeError.invalidResponse("Unable to encode JSON-RPC request.")
            }
            guard let inputPipe else {
                throw BridgeError.invalidResponse("Codex app-server input is not available.")
            }
            try inputPipe.fileHandleForWriting.write(contentsOf: lineData)
        } catch {
            pending.removeValue(forKey: id)
            completion(.failure(error))
        }
    }

    private func failPendingLocked(_ message: String) {
        let callbacks = pending.values
        pending.removeAll()
        for callback in callbacks {
            callback(.failure(BridgeError.remote(message)))
        }
    }

    private func handleOutputLocked(_ data: Data) {
        outputBuffer.append(data)

        while let newline = outputBuffer.firstIndex(of: 10) {
            let lineData = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !lineData.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any] else {
                continue
            }
            handleMessageLocked(object)
        }
    }

    private func handleMessageLocked(_ object: [String: Any]) {
        if let id = object["id"] as? Int,
           let completion = pending.removeValue(forKey: id) {
            if let error = object["error"] as? [String: Any] {
                completion(.failure(BridgeError.remote(error["message"] as? String ?? "Unknown Codex error")))
            } else {
                completion(.success(object["result"] as? [String: Any] ?? [:]))
            }
            return
        }

        guard let method = object["method"] as? String else { return }
        let params = object["params"] as? [String: Any] ?? [:]

        switch method {
        case "thread/started":
            if let thread = params["thread"] as? [String: Any],
               let id = thread["id"] as? String {
                setThreadIDLocked(id)
            }
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String {
                awaitingFirstTurnOutput = false
                onEvent?(.streamDelta(agentID, delta))
            }
        case "turn/completed":
            awaitingFirstTurnOutput = false
            if let threadID {
                CodexHistoryVisibilityRegistrar.register(threadID: threadID, workspaceRoot: context.rootPath)
                CodexHistoryVisibilityRegistrar.registerSoon(threadID: threadID, workspaceRoot: context.rootPath)
            }
            onEvent?(.completed(agentID))
        case "error":
            awaitingFirstTurnOutput = false
            onEvent?(.failed(agentID, params["message"] as? String ?? "Codex app-server error"))
        default:
            break
        }
    }

    private func setThreadIDLocked(_ id: String) {
        threadID = id
        UserDefaults.standard.set(id, forKey: NativeSessionKeys.codexThreadId)
        UserDefaults.standard.set(context.rootPath, forKey: NativeSessionKeys.codexThreadRoot)
        CodexHistoryVisibilityRegistrar.register(threadID: id, workspaceRoot: context.rootPath)
        CodexHistoryVisibilityRegistrar.registerSoon(threadID: id, workspaceRoot: context.rootPath)
    }

    private func setThreadNameLocked(threadID: String, title: String) {
        UserDefaults.standard.set(title, forKey: NativeSessionKeys.codexThreadTitle)
        requestLocked(method: "thread/name/set", params: [
            "threadId": threadID,
            "name": title
        ]) { [weak self] result in
            if case .failure(let error) = result {
                self?.onEvent?(.failed(self?.agentID ?? "agent1", "Unable to name Codex thread: \(error.localizedDescription)"))
            }
            if let self {
                CodexHistoryVisibilityRegistrar.register(threadID: threadID, workspaceRoot: self.context.rootPath)
                CodexHistoryVisibilityRegistrar.registerSoon(threadID: threadID, workspaceRoot: self.context.rootPath)
            }
        }
    }

    private static func isImageAttachment(_ url: URL) -> Bool {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "gif", "tiff", "bmp"]
        return imageExtensions.contains(url.pathExtension.lowercased())
    }
}

private final class CodexCLISession: CodexSessionControlling, @unchecked Sendable {
    var onEvent: ((AgentBridgeEvent) -> Void)?
    let agentID: String

    private let executablePath: String
    private let context: ConversationContext
    private let queue = DispatchQueue(label: "FloatScope.CodexCLISession")
    private var runningProcess: Process?
    private var outputBuffer = Data()
    private var streamedTextDuringRun = false
    private var failureText = ""
    private var sessionID: String?

    init(agentID: String, executablePath: String, context: ConversationContext) {
        self.agentID = agentID
        self.executablePath = executablePath
        self.context = context
        let defaults = UserDefaults.standard
        if defaults.string(forKey: NativeSessionKeys.codexThreadRoot) == context.rootPath {
            self.sessionID = defaults.string(forKey: NativeSessionKeys.codexThreadId)
            if let sessionID {
                CodexHistoryVisibilityRegistrar.register(threadID: sessionID, workspaceRoot: context.rootPath)
                CodexHistoryVisibilityRegistrar.registerSoon(threadID: sessionID, workspaceRoot: context.rootPath)
            }
        } else {
            defaults.removeObject(forKey: NativeSessionKeys.codexThreadId)
            defaults.removeObject(forKey: NativeSessionKeys.codexThreadRoot)
            defaults.removeObject(forKey: NativeSessionKeys.codexThreadTitle)
        }
    }

    func start() {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            onEvent?(.failed(agentID, "Executable not found: \(executablePath)"))
            return
        }
        onEvent?(.started(agentID))
    }

    func send(message: String, attachments: [URL], modelPreset: CodexModelPreset, effortPreset: ReasoningEffortPreset) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.runningProcess == nil else {
                self.onEvent?(.failed(self.agentID, "Codex is still responding."))
                return
            }
            self.runLocked(message: message, attachments: attachments, modelPreset: modelPreset, effortPreset: effortPreset)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.runningProcess?.terminate()
            self?.runningProcess = nil
        }
    }

    func resetConversation() {
        queue.async { [weak self] in
            guard let self else { return }
            self.sessionID = nil
            UserDefaults.standard.removeObject(forKey: NativeSessionKeys.codexThreadId)
            UserDefaults.standard.removeObject(forKey: NativeSessionKeys.codexThreadRoot)
            UserDefaults.standard.removeObject(forKey: NativeSessionKeys.codexThreadTitle)
        }
    }

    func rollbackLastTurns(_ count: Int) {
        guard count > 0 else { return }
        onEvent?(.failed(agentID, "Rollback is only available in Codex App mode for now."))
    }

    func selectConversation(threadID: String?, title: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.sessionID = threadID
            if let threadID {
                UserDefaults.standard.set(threadID, forKey: NativeSessionKeys.codexThreadId)
                UserDefaults.standard.set(self.context.rootPath, forKey: NativeSessionKeys.codexThreadRoot)
                UserDefaults.standard.set(title, forKey: NativeSessionKeys.codexThreadTitle)
                CodexHistoryVisibilityRegistrar.register(threadID: threadID, workspaceRoot: self.context.rootPath)
                CodexHistoryVisibilityRegistrar.registerSoon(threadID: threadID, workspaceRoot: self.context.rootPath)
            } else {
                UserDefaults.standard.removeObject(forKey: NativeSessionKeys.codexThreadId)
                UserDefaults.standard.removeObject(forKey: NativeSessionKeys.codexThreadRoot)
                UserDefaults.standard.removeObject(forKey: NativeSessionKeys.codexThreadTitle)
            }
        }
    }

    private func runLocked(message: String, attachments: [URL], modelPreset: CodexModelPreset, effortPreset: ReasoningEffortPreset) {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            onEvent?(.failed(agentID, "Executable not found: \(executablePath)"))
            return
        }

        do {
            try context.ensureRoot()
        } catch {
            onEvent?(.failed(agentID, error.localizedDescription))
            return
        }

        CodexHistoryVisibilityRegistrar.registerWorkspace(workspaceRoot: context.rootPath)
        if let sessionID {
            CodexHistoryVisibilityRegistrar.register(threadID: sessionID, workspaceRoot: context.rootPath)
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.currentDirectoryURL = URL(fileURLWithPath: context.rootPath)
        process.arguments = buildArguments(message: message, attachments: attachments, modelPreset: modelPreset, effortPreset: effortPreset)
        process.standardOutput = output
        process.standardError = output
        process.environment = ProcessInfo.processInfo.environment.merging([
            "NO_COLOR": "1"
        ]) { _, new in new }

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let session = self else { return }
            session.queue.async {
                session.outputBuffer.append(data)
                while let newline = session.outputBuffer.firstIndex(of: 10) {
                    let lineData = session.outputBuffer[..<newline]
                    session.outputBuffer.removeSubrange(...newline)
                    session.handleCodexLineLocked(Data(lineData))
                }
            }
        }

        process.terminationHandler = { [weak self] terminated in
            guard let session = self else { return }
            session.queue.async {
                session.runningProcess = nil
                if !session.outputBuffer.isEmpty {
                    session.handleCodexLineLocked(session.outputBuffer)
                    session.outputBuffer.removeAll()
                }
                if terminated.terminationStatus == 0 {
                    if let sessionID = session.sessionID {
                        CodexHistoryVisibilityRegistrar.register(threadID: sessionID, workspaceRoot: session.context.rootPath)
                        CodexHistoryVisibilityRegistrar.registerSoon(threadID: sessionID, workspaceRoot: session.context.rootPath)
                        CodexHistoryVisibilityRegistrar.renameSoon(threadID: sessionID, title: session.cliTitle())
                    }
                    session.onEvent?(.completed(session.agentID))
                } else {
                    let details = session.failureText.trimmingCharacters(in: .whitespacesAndNewlines)
                    session.onEvent?(.failed(session.agentID, details.isEmpty ? "codex exec exited with status \(terminated.terminationStatus)" : details))
                }
            }
        }

        do {
            outputBuffer.removeAll()
            failureText.removeAll()
            streamedTextDuringRun = false
            runningProcess = process
            try process.run()
        } catch {
            runningProcess = nil
            onEvent?(.failed(agentID, error.localizedDescription))
        }
    }

    private func buildArguments(message: String, attachments: [URL], modelPreset: CodexModelPreset, effortPreset: ReasoningEffortPreset) -> [String] {
        var arguments: [String]
        if let sessionID {
            arguments = ["exec", "resume", "--json", "--skip-git-repo-check"]
            arguments.append(contentsOf: ["-m", modelPreset.codexModel])
            arguments.append(contentsOf: ["-c", "model_reasoning_effort=\"\(effortPreset.rawValue)\""])
            for attachment in attachments where Self.isImageAttachment(attachment) {
                arguments.append(contentsOf: ["-i", attachment.path])
            }
            arguments.append(sessionID)
            arguments.append(promptWithFileNotes(message: message, attachments: attachments))
        } else {
            arguments = ["exec", "--json", "--skip-git-repo-check", "-C", context.rootPath]
            arguments.append(contentsOf: ["-m", modelPreset.codexModel])
            arguments.append(contentsOf: ["-c", "model_reasoning_effort=\"\(effortPreset.rawValue)\""])
            for attachment in attachments where Self.isImageAttachment(attachment) {
                arguments.append(contentsOf: ["-i", attachment.path])
            }
            arguments.append(promptWithFileNotes(message: message, attachments: attachments))
        }
        return arguments
    }

    private func promptWithFileNotes(message: String, attachments: [URL]) -> String {
        let files = attachments.filter { !Self.isImageAttachment($0) }
        guard !files.isEmpty else { return message }
        let notes = files.map { "[Attachment: \($0.path)]" }.joined(separator: "\n")
        return "\(message)\n\n\(notes)"
    }

    private func handleCodexLineLocked(_ data: Data) {
        guard !data.isEmpty else { return }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            captureSessionID(from: object)
            if let text = extractDeltaText(from: object), !text.isEmpty {
                streamedTextDuringRun = true
                onEvent?(.streamDelta(agentID, text))
                return
            }
            if !streamedTextDuringRun,
               let text = extractFinalAssistantText(from: object),
               !text.isEmpty {
                streamedTextDuringRun = true
                onEvent?(.streamDelta(agentID, text))
            }
            return
        }

        if let text = String(data: data, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failureText += text + "\n"
        }
    }

    private func extractDeltaText(from object: [String: Any]) -> String? {
        let type = object["type"] as? String ?? ""
        if type.localizedCaseInsensitiveContains("delta") {
            return object["delta"] as? String
                ?? object["text"] as? String
                ?? object["content"] as? String
        }
        return nil
    }

    private func extractFinalAssistantText(from object: [String: Any]) -> String? {
        guard object["type"] as? String == "response_item",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "message",
              payload["role"] as? String == "assistant",
              let content = payload["content"] as? [[String: Any]] else {
            return nil
        }
        return content.compactMap { item -> String? in
            let type = item["type"] as? String
            guard type == "output_text" || type == "text" else { return nil }
            return item["text"] as? String
        }.joined()
    }

    private func captureSessionID(from object: Any) {
        guard sessionID == nil else { return }
        if let id = findCodexSessionID(in: object) {
            sessionID = id
            let title = cliTitle()
            UserDefaults.standard.set(id, forKey: NativeSessionKeys.codexThreadId)
            UserDefaults.standard.set(context.rootPath, forKey: NativeSessionKeys.codexThreadRoot)
            UserDefaults.standard.set(title, forKey: NativeSessionKeys.codexThreadTitle)
            CodexHistoryVisibilityRegistrar.register(threadID: id, workspaceRoot: context.rootPath)
            CodexHistoryVisibilityRegistrar.registerSoon(threadID: id, workspaceRoot: context.rootPath)
            CodexHistoryVisibilityRegistrar.renameSoon(threadID: id, title: title)
        }
    }

    private func cliTitle() -> String {
        let title = context.title
        let updated: String
        if title.hasPrefix("群聊 CLI ") || title.hasPrefix("CLI ") {
            updated = title
        } else if title.hasPrefix("群聊 ") {
            updated = "群聊 CLI " + String(title.dropFirst("群聊 ".count))
        } else {
            updated = "CLI " + title
        }
        ConversationContext.setActiveTitle(updated)
        return updated
    }

    private func findCodexSessionID(in value: Any) -> String? {
        guard let dictionary = value as? [String: Any] else { return nil }
        if dictionary["type"] as? String == "session_meta",
           let payload = dictionary["payload"] as? [String: Any],
           let id = payload["id"] as? String,
           isUUIDLike(id) {
            return id
        }
        if let payload = dictionary["payload"] as? [String: Any],
           let id = findCodexSessionID(in: payload) {
            return id
        }
        if let id = dictionary["id"] as? String,
           let type = dictionary["type"] as? String,
           type.localizedCaseInsensitiveContains("session"),
           isUUIDLike(id) {
            return id
        }
        for key in ["session_id", "sessionId", "sessionID", "thread_id", "threadId", "threadID"] {
            if let id = dictionary[key] as? String, isUUIDLike(id) {
                return id
            }
        }
        for nested in dictionary.values {
            if let nestedDictionary = nested as? [String: Any],
               let id = findCodexSessionID(in: nestedDictionary) {
                return id
            }
        }
        return nil
    }

    private func isUUIDLike(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil
    }

    private static func isImageAttachment(_ url: URL) -> Bool {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "gif", "tiff", "bmp"]
        return imageExtensions.contains(url.pathExtension.lowercased())
    }
}

private final class OpencodeRunSession: @unchecked Sendable {
    var onEvent: ((AgentBridgeEvent) -> Void)?
    let agentID: String

    private let executablePath: String
    private let appBundlePath: String?
    private let context: ConversationContext
    private let queue = DispatchQueue(label: "FloatScope.OpencodeRunSession")
    private var runningProcess: Process?
    private var outputBuffer = Data()
    private var sessionID: String?
    private var failureText = ""
    private var streamedTextDuringRun = false
    private var sessionNotFoundDuringRun = false

    init(agentID: String, executablePath: String, appBundlePath: String?, context: ConversationContext) {
        self.agentID = agentID
        self.executablePath = executablePath
        self.appBundlePath = appBundlePath
        self.context = context
        let defaults = UserDefaults.standard
        if defaults.string(forKey: NativeSessionKeys.opencodeSessionRoot) == context.rootPath {
            self.sessionID = defaults.string(forKey: NativeSessionKeys.opencodeSessionId)
        } else {
            defaults.removeObject(forKey: NativeSessionKeys.opencodeSessionId)
            defaults.removeObject(forKey: NativeSessionKeys.opencodeSessionRoot)
            defaults.removeObject(forKey: NativeSessionKeys.opencodeSessionTitle)
        }
    }

    func start() {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            onEvent?(.failed(agentID, "Executable not found: \(executablePath)"))
            return
        }
        onEvent?(.started(agentID))
    }

    func send(message: String, attachments: [URL], modelPreset: OpenCodeModelPreset, variantPreset: OpenCodeVariantPreset) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.runningProcess == nil else {
                self.onEvent?(.failed(agentID, "Agent is still responding."))
                return
            }
            self.runLocked(message: message, attachments: attachments, modelPreset: modelPreset, variantPreset: variantPreset)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.runningProcess?.terminate()
            self?.runningProcess = nil
        }
    }

    func resetConversation() {
        queue.async { [weak self] in
            guard let self else { return }
            self.sessionID = nil
            UserDefaults.standard.removeObject(forKey: NativeSessionKeys.opencodeSessionId)
            UserDefaults.standard.removeObject(forKey: NativeSessionKeys.opencodeSessionRoot)
            UserDefaults.standard.removeObject(forKey: NativeSessionKeys.opencodeSessionTitle)
        }
    }

    func rollbackLastTurns(_ count: Int) {
        queue.async { [weak self] in
            guard let self, count > 0, let sessionID else { return }
            OpenCodeHistoryVisibilityRegistrar.rollbackLastTurns(sessionID: sessionID, count: count, workspaceRoot: self.context.rootPath)
        }
    }

    func selectConversation(sessionID: String?, title: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.sessionID = sessionID
            if let sessionID {
                UserDefaults.standard.set(sessionID, forKey: NativeSessionKeys.opencodeSessionId)
                UserDefaults.standard.set(self.context.rootPath, forKey: NativeSessionKeys.opencodeSessionRoot)
                UserDefaults.standard.set(title, forKey: NativeSessionKeys.opencodeSessionTitle)
                OpenCodeHistoryVisibilityRegistrar.registerSession(sessionID: sessionID, workspaceRoot: self.context.rootPath)
            } else {
                UserDefaults.standard.removeObject(forKey: NativeSessionKeys.opencodeSessionId)
                UserDefaults.standard.removeObject(forKey: NativeSessionKeys.opencodeSessionRoot)
                UserDefaults.standard.removeObject(forKey: NativeSessionKeys.opencodeSessionTitle)
            }
        }
    }

    private func runLocked(
        message: String,
        attachments: [URL],
        modelPreset: OpenCodeModelPreset,
        variantPreset: OpenCodeVariantPreset,
        retryingAfterSessionLoss: Bool = false
    ) {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            onEvent?(.failed(agentID, "Executable not found: \(executablePath)"))
            return
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)

        do {
            try context.ensureRoot()
        } catch {
            onEvent?(.failed(agentID, error.localizedDescription))
            return
        }

        let title = context.title
        OpenCodeHistoryVisibilityRegistrar.registerProject(workspaceRoot: context.rootPath)
        if let sessionID {
            OpenCodeHistoryVisibilityRegistrar.registerSession(sessionID: sessionID, workspaceRoot: context.rootPath)
        }

        var arguments = ["run", "--format", "json", "--dir", context.rootPath]
        arguments.append(contentsOf: ["--model", modelPreset.modelIdentifier])
        if let variant = variantPreset.argumentValue {
            arguments.append(contentsOf: ["--variant", variant])
        }
        if let sessionID {
            arguments.append(contentsOf: ["--session", sessionID])
        } else {
            arguments.append(contentsOf: ["--title", title])
            UserDefaults.standard.set(title, forKey: NativeSessionKeys.opencodeSessionTitle)
        }
        for attachment in attachments {
            arguments.append(contentsOf: ["--file", attachment.path])
        }
        arguments.append("--")
        arguments.append(message)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        process.environment = ProcessInfo.processInfo.environment.merging([
            "NO_COLOR": "1"
        ]) { _, new in new }

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let session = self else { return }
            session.queue.async {
                session.outputBuffer.append(data)
                while let newline = session.outputBuffer.firstIndex(of: 10) {
                    let lineData = session.outputBuffer[..<newline]
                    session.outputBuffer.removeSubrange(...newline)
                    session.handleOpencodeLineLocked(Data(lineData))
                }
            }
        }

        process.terminationHandler = { [weak self] terminated in
            guard let session = self else { return }
            session.queue.async {
                session.runningProcess = nil
                if terminated.terminationStatus == 0 {
                    if !session.streamedTextDuringRun,
                       let sessionID = session.sessionID,
                       let fallback = OpenCodeHistoryVisibilityRegistrar.latestAssistantText(sessionID: sessionID) {
                        session.onEvent?(.streamDelta(session.agentID, fallback))
                    }
                    session.onEvent?(.completed(session.agentID))
                } else if session.sessionNotFoundDuringRun && !retryingAfterSessionLoss {
                    session.sessionNotFoundDuringRun = false
                    session.clearSessionLocked()
                    session.runLocked(
                        message: message,
                        attachments: attachments,
                        modelPreset: modelPreset,
                        variantPreset: variantPreset,
                        retryingAfterSessionLoss: true
                    )
                } else {
                    session.sessionNotFoundDuringRun = false
                    let details = session.cleanedFailureTextLocked()
                    let message = details.isEmpty
                        ? "opencode exited with status \(terminated.terminationStatus)"
                        : details
                    session.onEvent?(.failed(session.agentID, message))
                }
            }
        }

        do {
            outputBuffer.removeAll()
            failureText.removeAll()
            streamedTextDuringRun = false
            sessionNotFoundDuringRun = false
            runningProcess = process
            try process.run()
        } catch {
            runningProcess = nil
            onEvent?(.failed(agentID, error.localizedDescription))
        }
    }

    private func handleOpencodeLineLocked(_ data: Data) {
        guard !data.isEmpty else { return }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            captureSessionID(from: object)
            if let text = extractText(from: object), !text.isEmpty {
                if noteSessionNotFoundIfNeeded(text) {
                    return
                }
                streamedTextDuringRun = true
                onEvent?(.streamDelta(agentID, text))
            }
            return
        }

        if let text = String(data: data, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failureText += text + "\n"
            if noteSessionNotFoundIfNeeded(text) {
                return
            }
            streamedTextDuringRun = true
            onEvent?(.streamDelta(agentID, text + "\n"))
        }
    }

    private func clearSessionLocked() {
        sessionID = nil
        UserDefaults.standard.removeObject(forKey: NativeSessionKeys.opencodeSessionId)
        UserDefaults.standard.removeObject(forKey: NativeSessionKeys.opencodeSessionTitle)
    }

    private func noteSessionNotFoundIfNeeded(_ text: String) -> Bool {
        if text.localizedCaseInsensitiveContains("session not found") {
            sessionNotFoundDuringRun = true
            return true
        }
        return false
    }

    private func cleanedFailureTextLocked() -> String {
        failureText
            .replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractText(from object: [String: Any]) -> String? {
        if let part = object["part"] as? [String: Any] {
            if let text = part["text"] as? String { return text }
            if let content = part["content"] as? String { return content }
        }

        if let type = object["type"] as? String {
            switch type {
            case "assistant", "message", "text", "content":
                return object["text"] as? String ?? object["content"] as? String
            case "part":
                return object["text"] as? String
            default:
                break
            }
        }

        if let message = object["message"] as? [String: Any] {
            if let text = message["text"] as? String { return text }
            if let content = message["content"] as? String { return content }
            if let parts = message["content"] as? [[String: Any]] {
                return parts.compactMap { $0["text"] as? String }.joined()
            }
        }

        if let text = object["text"] as? String { return text }
        if let content = object["content"] as? String { return content }
        return nil
    }

    private func captureSessionID(from object: Any) {
        guard sessionID == nil else { return }
        if let id = findSessionID(in: object) {
            sessionID = id
            UserDefaults.standard.set(id, forKey: NativeSessionKeys.opencodeSessionId)
            UserDefaults.standard.set(context.rootPath, forKey: NativeSessionKeys.opencodeSessionRoot)
            OpenCodeHistoryVisibilityRegistrar.registerSession(sessionID: id, workspaceRoot: context.rootPath)
        }
    }

    private func findSessionID(in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            if let session = dictionary["session"] as? [String: Any],
               let id = session["id"] as? String,
               !id.isEmpty {
                return id
            }
            if let type = dictionary["type"] as? String,
               type.localizedCaseInsensitiveContains("session"),
               let id = dictionary["id"] as? String,
               !id.isEmpty {
                return id
            }
            for key in ["sessionID", "sessionId", "session_id", "id"] {
                if key.lowercased().contains("session"),
                   let id = dictionary[key] as? String,
                   !id.isEmpty {
                    return id
                }
            }
            for nested in dictionary.values {
                if let id = findSessionID(in: nested) {
                    return id
                }
            }
        }

        if let array = value as? [Any] {
            for nested in array {
                if let id = findSessionID(in: nested) {
                    return id
                }
            }
        }

        return nil
    }
}

private final class GenericCLISession: @unchecked Sendable {
    var onEvent: ((AgentBridgeEvent) -> Void)?

    private let config: AgentRuntimeConfig
    private let context: ConversationContext
    private let queue: DispatchQueue
    private var runningProcess: Process?

    init(config: AgentRuntimeConfig, context: ConversationContext) {
        self.config = config
        self.context = context
        self.queue = DispatchQueue(label: "FloatScope.GenericCLISession.\(config.id)")
    }

    func start() {
        AgentApplicationLauncher.openIfConfigured(config.appBundlePath)
        guard !config.executablePath.isEmpty else {
            onEvent?(.failed(config.id, "Executable path is empty."))
            return
        }
        guard FileManager.default.isExecutableFile(atPath: config.executablePath) else {
            onEvent?(.failed(config.id, "Executable not found: \(config.executablePath)"))
            return
        }
        onEvent?(.started(config.id))
    }

    func send(message: String, attachments: [URL]) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.runningProcess == nil else {
                self.onEvent?(.failed(self.config.id, "Agent is still responding."))
                return
            }
            self.runLocked(message: message, attachments: attachments)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.runningProcess?.terminate()
            self?.runningProcess = nil
        }
    }

    func resetConversation() {}

    private func runLocked(message: String, attachments: [URL]) {
        AgentApplicationLauncher.openIfConfigured(config.appBundlePath)
        guard FileManager.default.isExecutableFile(atPath: config.executablePath) else {
            onEvent?(.failed(config.id, "Executable not found: \(config.executablePath)"))
            return
        }

        do {
            try context.ensureRoot()
        } catch {
            onEvent?(.failed(config.id, error.localizedDescription))
            return
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: config.executablePath)
        process.currentDirectoryURL = URL(fileURLWithPath: context.rootPath)
        process.arguments = buildArguments(message: message, attachments: attachments)
        process.standardOutput = output
        process.standardError = output
        process.environment = ProcessInfo.processInfo.environment.merging([
            "NO_COLOR": "1",
            "FLOATSCOPE_AGENT_ID": config.id,
            "FLOATSCOPE_AGENT_KIND": config.kind,
            "FLOATSCOPE_MODEL": config.model ?? "",
            "FLOATSCOPE_EFFORT": config.effort ?? config.variant ?? "",
            "FLOATSCOPE_CONVERSATION_ROOT": context.rootPath
        ]) { _, new in new }

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            self?.onEvent?(.streamDelta(self?.config.id ?? "", text))
        }

        process.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            self.queue.async {
                self.runningProcess = nil
                if terminated.terminationStatus == 0 {
                    self.onEvent?(.completed(self.config.id))
                } else {
                    self.onEvent?(.failed(self.config.id, "CLI exited with status \(terminated.terminationStatus)"))
                }
            }
        }

        do {
            runningProcess = process
            try process.run()
        } catch {
            runningProcess = nil
            onEvent?(.failed(config.id, error.localizedDescription))
        }
    }

    private func buildArguments(message: String, attachments: [URL]) -> [String] {
        switch config.kind {
        case "claude-code":
            return [message] + attachments.map(\.path)
        case "openclaw":
            return [message] + attachments.flatMap { ["--file", $0.path] }
        default:
            return [message] + attachments.map(\.path)
        }
    }
}

private enum OpenCodeHistoryVisibilityRegistrar {
    static func registerProject(workspaceRoot: String) {
        let now = currentMilliseconds()
        let sql = """
        update project
        set time_updated = \(now)
        where id = 'global';
        update session
        set project_id = 'global',
            directory = '\(escape(workspaceRoot))',
            path = '\(escape(relativePath(for: workspaceRoot)))',
            time_updated = max(time_updated, \(now))
        where directory = '\(escape(workspaceRoot))';
        """
        run(sql)
    }

    static func registerSession(sessionID: String, workspaceRoot: String) {
        registerProject(workspaceRoot: workspaceRoot)
        let relativePath = relativePath(for: workspaceRoot)
        let now = currentMilliseconds()
        let sql = """
        update session
        set project_id = 'global',
            directory = '\(escape(workspaceRoot))',
            path = '\(escape(relativePath))',
            time_updated = max(time_updated, \(now))
        where id = '\(escape(sessionID))';
        """
        run(sql)
        registerDesktopProjectState(workspaceRoot: workspaceRoot, sessionID: sessionID)
    }

    static func latestAssistantText(sessionID: String) -> String? {
        let sql = """
        select p.data
        from part p
        join message m on m.id = p.message_id
        where p.session_id = '\(escape(sessionID))'
          and json_extract(m.data, '$.role') = 'assistant'
          and json_extract(p.data, '$.type') = 'text'
        order by p.time_created desc
        limit 1;
        """
        guard let raw = run(sql, captureOutput: true),
              let data = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["text"] as? String
    }

    static func rollbackLastTurns(sessionID: String, count: Int, workspaceRoot: String) {
        let escapedSession = escape(sessionID)
        let safeCount = max(1, count)
        let cutoff = """
        (select time_created
         from message
         where session_id = '\(escapedSession)'
           and json_extract(data, '$.role') = 'user'
         order by time_created desc
         limit 1 offset \(safeCount - 1))
        """
        let sql = """
        delete from part
        where session_id = '\(escapedSession)'
          and message_id in (
            select id from message
            where session_id = '\(escapedSession)'
              and time_created >= \(cutoff)
          );
        delete from message
        where session_id = '\(escapedSession)'
          and time_created >= \(cutoff);
        update session
        set time_updated = coalesce(
                (select max(time_created) from message where session_id = '\(escapedSession)'),
                time_updated
            )
        where id = '\(escapedSession)';
        """
        run(sql)
        registerSession(sessionID: sessionID, workspaceRoot: workspaceRoot)
    }

    private static func run(_ sql: String) {
        _ = run(sql, captureOutput: false)
    }

    private static func run(_ sql: String, captureOutput: Bool) -> String? {
        let dbURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local")
            .appendingPathComponent("share")
            .appendingPathComponent("opencode")
            .appendingPathComponent("opencode.db")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbURL.path, sql]
        process.standardOutput = output
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        guard captureOutput, process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private static func currentMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static func registerDesktopProjectState(workspaceRoot: String, sessionID: String) {
        let stateURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("ai.opencode.desktop")
            .appendingPathComponent("opencode.global.dat")
        guard let data = try? Data(contentsOf: stateURL),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        var layout = (root["layout.page"] as? String)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            ?? [:]
        var lastProjectSession = layout["lastProjectSession"] as? [String: Any] ?? [:]
        lastProjectSession[workspaceRoot] = [
            "directory": workspaceRoot,
            "id": sessionID,
            "at": currentMilliseconds()
        ]
        layout["lastProjectSession"] = lastProjectSession

        var workspaceName = layout["workspaceName"] as? [String: Any] ?? [:]
        workspaceName[workspaceRoot] = URL(fileURLWithPath: workspaceRoot).lastPathComponent
        layout["workspaceName"] = workspaceName

        do {
            let layoutData = try JSONSerialization.data(withJSONObject: layout, options: [])
            root["layout.page"] = String(data: layoutData, encoding: .utf8)
            let updated = try JSONSerialization.data(withJSONObject: root, options: [])
            try updated.write(to: stateURL, options: [.atomic])
        } catch {
            // UI project cache registration is best-effort; OpenCode's SQLite history remains canonical.
        }
    }

    private static func relativePath(for workspaceRoot: String) -> String {
        workspaceRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

private enum CodexHistoryVisibilityRegistrar {
    private static let maintenance = CodexHistoryVisibilityMaintenance()

    static func registerWorkspace(workspaceRoot: String) {
        updateState { root in
            registerWorkspaceRoot(workspaceRoot, in: &root)
        }
    }

    static func register(threadID: String, workspaceRoot: String) {
        remember(threadID: threadID, workspaceRoot: workspaceRoot)
        scrub(threadID: threadID, workspaceRoot: workspaceRoot)
    }

    static func registerSoon(threadID: String, workspaceRoot: String) {
        remember(threadID: threadID, workspaceRoot: workspaceRoot)
        for delay in [0.35, 1.25, 3.0, 8.0, 20.0] {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                scrub(threadID: threadID, workspaceRoot: workspaceRoot)
            }
        }
    }

    static func renameSoon(threadID: String, title: String) {
        rename(threadID: threadID, title: title)
        for delay in [0.35, 1.25, 3.0, 8.0, 20.0] {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                rename(threadID: threadID, title: title)
            }
        }
    }

    private static func remember(threadID: String, workspaceRoot: String) {
        maintenance.remember(threadID: threadID, workspaceRoot: workspaceRoot) { threads in
            updateState { root in
                for (threadID, workspaceRoot) in threads {
                    scrub(threadID: threadID, workspaceRoot: workspaceRoot, in: &root)
                }
            }
        }
    }

    private static func scrub(threadID: String, workspaceRoot: String) {
        updateState { root in
            scrub(threadID: threadID, workspaceRoot: workspaceRoot, in: &root)
        }
    }

    private static func scrub(threadID: String, workspaceRoot: String, in root: inout [String: Any]) {
        var threadIDs = root["projectless-thread-ids"] as? [String] ?? []
        threadIDs.removeAll { $0 == threadID }
        root["projectless-thread-ids"] = threadIDs

        var workspaceHints = root["thread-workspace-root-hints"] as? [String: Any] ?? [:]
        workspaceHints[threadID] = workspaceRoot
        root["thread-workspace-root-hints"] = workspaceHints

        registerWorkspaceRoot(workspaceRoot, in: &root)
    }

    private static func updateState(_ update: (inout [String: Any]) -> Void) {
        let codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let stateURL = codexHome.appendingPathComponent(".codex-global-state.json")

        do {
            let data = (try? Data(contentsOf: stateURL)) ?? Data("{}".utf8)
            guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            update(&root)

            let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try updated.write(to: stateURL, options: [.atomic])
        } catch {
            // History visibility is best-effort; message delivery must not fail because the UI index is locked.
        }
    }

    private static func rename(threadID: String, title: String) {
        let indexURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("session_index.jsonl")

        do {
            let raw = (try? String(contentsOf: indexURL, encoding: .utf8)) ?? ""
            var didUpdate = false
            let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine -> String? in
                guard !rawLine.isEmpty,
                      let data = rawLine.data(using: .utf8),
                      var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["id"] as? String == threadID else {
                    return rawLine.isEmpty ? nil : String(rawLine)
                }
                object["thread_name"] = title
                didUpdate = true
                guard let updated = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                      let line = String(data: updated, encoding: .utf8) else {
                    return String(rawLine)
                }
                return line
            }

            var output = lines.joined(separator: "\n")
            if !didUpdate {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let object: [String: Any] = [
                    "id": threadID,
                    "thread_name": title,
                    "updated_at": formatter.string(from: Date())
                ]
                if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                   let line = String(data: data, encoding: .utf8) {
                    if !output.isEmpty {
                        output += "\n"
                    }
                    output += line
                }
            }
            if !output.hasSuffix("\n") {
                output += "\n"
            }
            try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try output.write(to: indexURL, atomically: true, encoding: .utf8)
        } catch {
            // Best-effort only; Codex can still answer even if the sidebar index is locked.
        }
    }

    private static func registerWorkspaceRoot(_ workspaceRoot: String, in root: inout [String: Any]) {
        var savedRoots = root["electron-saved-workspace-roots"] as? [String] ?? []
        appendUnique(workspaceRoot, to: &savedRoots)
        root["electron-saved-workspace-roots"] = savedRoots

        var projectOrder = root["project-order"] as? [String] ?? []
        appendUnique(workspaceRoot, to: &projectOrder)
        root["project-order"] = projectOrder

        var activeRoots = root["active-workspace-roots"] as? [String] ?? []
        appendUnique(workspaceRoot, to: &activeRoots)
        root["active-workspace-roots"] = activeRoots

        var atomState = root["electron-persisted-atom-state"] as? [String: Any] ?? [:]
        var collapsedGroups = atomState["sidebar-collapsed-groups"] as? [String: Any] ?? [:]
        collapsedGroups[workspaceRoot] = false
        atomState["sidebar-collapsed-groups"] = collapsedGroups
        root["electron-persisted-atom-state"] = atomState
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        if !values.contains(value) {
            values.append(value)
        }
    }
}

private final class CodexHistoryVisibilityMaintenance: @unchecked Sendable {
    private let queue = DispatchQueue(label: "FloatScope.CodexHistoryVisibility")
    private var maintainedThreads: [String: String] = [:]
    private var timer: DispatchSourceTimer?

    func remember(threadID: String, workspaceRoot: String, tick: @escaping @Sendable ([String: String]) -> Void) {
        queue.async {
            self.maintainedThreads[threadID] = workspaceRoot
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let threads = self.maintainedThreads
                guard !threads.isEmpty else { return }
                tick(threads)
            }
            self.timer = timer
            timer.resume()
        }
    }
}

private enum BridgeError: LocalizedError {
    case invalidResponse(String)
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let message), .remote(let message):
            message
        }
    }
}
