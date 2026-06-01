import Foundation

enum AgentBridgeEvent {
    case started(String)
    case streamDelta(String, String)
    case completed(String)
    case failed(String, String)
}

final class AgentBridge: @unchecked Sendable {
    var onEvent: ((AgentBridgeEvent) -> Void)?

    private var codex: CodexAppServerSession?
    private var opencode: OpencodeRunSession?
    private var genericSessions: [String: GenericCLISession] = [:]
    private var configs: [String: AgentRuntimeConfig] = [:]

    func configure(config: AgentHubConfig) {
        stopAll()
        genericSessions.removeAll()
        configs = [:]
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
                let session = CodexAppServerSession(agentID: agent.id, executablePath: agent.executablePath, context: ConversationContext(rootPath: visibleRoot))
                session.onEvent = { [weak self] event in self?.onEvent?(event) }
                codex = session
            case "opencode-run" where index == 1:
                let session = OpencodeRunSession(agentID: agent.id, executablePath: agent.executablePath, context: ConversationContext(rootPath: root))
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

        let opencodeRoot = URL(fileURLWithPath: conversationRoot).standardizedFileURL.path
        let visibleRoot = CodexWorkspaceResolver.visibleWorkspaceRoot(preferredRoot: conversationRoot)
        let opencodeContext = ConversationContext(rootPath: opencodeRoot)
        let codexContext = ConversationContext(rootPath: visibleRoot)
        CodexHistoryVisibilityRegistrar.registerWorkspace(workspaceRoot: visibleRoot)
        OpenCodeHistoryVisibilityRegistrar.registerProject(workspaceRoot: opencodeRoot)
        let codex = CodexAppServerSession(agentID: "agent1", executablePath: codexPath, context: codexContext)
        let opencode = OpencodeRunSession(agentID: "agent2", executablePath: opencodePath, context: opencodeContext)

        codex.onEvent = { [weak self] event in self?.onEvent?(event) }
        opencode.onEvent = { [weak self] event in self?.onEvent?(event) }

        self.codex = codex
        self.opencode = opencode
    }

    func startAll() {
        codex?.start()
        opencode?.start()
        genericSessions.values.forEach { $0.start() }
    }

    func send(
        agent: String,
        message: String,
        attachments: [URL] = [],
        codexModelPreset: CodexModelPreset,
        codexEffortPreset: ReasoningEffortPreset,
        agent2ModelPreset: OpenCodeModelPreset,
        agent2VariantPreset: OpenCodeVariantPreset
    ) {
        if agent == codex?.agentID {
            codex?.send(message: message, attachments: attachments, modelPreset: codexModelPreset, effortPreset: codexEffortPreset)
        } else if agent == opencode?.agentID {
            opencode?.send(message: message, attachments: attachments, modelPreset: agent2ModelPreset, variantPreset: agent2VariantPreset)
        } else {
            genericSessions[agent]?.send(message: message, attachments: attachments)
        }
    }

    func stopAll() {
        codex?.stop()
        opencode?.stop()
        genericSessions.values.forEach { $0.stop() }
    }

    func startNewConversation() {
        ConversationContext.resetActiveTitle()
        codex?.resetConversation()
        opencode?.resetConversation()
        genericSessions.values.forEach { $0.resetConversation() }
    }

    func selectConversation(_ entry: ConversationHistoryEntry) {
        ConversationContext.setActiveTitle(entry.title)
        codex?.selectConversation(threadID: entry.codexThreadID, title: entry.title)
        opencode?.selectConversation(sessionID: entry.opencodeSessionID, title: entry.title)
        genericSessions.values.forEach { $0.resetConversation() }
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

    static func resetActiveTitle() {
        UserDefaults.standard.set(makeTimestampTitle(), forKey: NativeSessionKeys.activeConversationTitle)
    }

    private static func makeTimestampTitle() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
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

private final class CodexAppServerSession: @unchecked Sendable {
    var onEvent: ((AgentBridgeEvent) -> Void)?
    let agentID: String

    private let executablePath: String
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
    private let queue = DispatchQueue(label: "FloatScope.CodexAppServerSession")

    init(agentID: String, executablePath: String, context: ConversationContext) {
        self.agentID = agentID
        self.executablePath = executablePath
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
                    self.onEvent?(.completed(agentID))
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
                if !session.isStopping && terminated.terminationStatus != 15 {
                    session.onEvent?(.failed(session.agentID, "Codex app-server exited with status \(terminated.terminationStatus)"))
                }
                session.isStopping = false
                session.process = nil
                session.inputPipe = nil
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
            if case .failure(let error) = result {
                self?.onEvent?(.failed(self?.agentID ?? "agent1", error.localizedDescription))
            }
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
                onEvent?(.streamDelta(agentID, delta))
            }
        case "turn/completed":
            if let threadID {
                CodexHistoryVisibilityRegistrar.register(threadID: threadID, workspaceRoot: context.rootPath)
                CodexHistoryVisibilityRegistrar.registerSoon(threadID: threadID, workspaceRoot: context.rootPath)
            }
            onEvent?(.completed(agentID))
        case "error":
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

private final class OpencodeRunSession: @unchecked Sendable {
    var onEvent: ((AgentBridgeEvent) -> Void)?
    let agentID: String

    private let executablePath: String
    private let context: ConversationContext
    private let queue = DispatchQueue(label: "FloatScope.OpencodeRunSession")
    private var runningProcess: Process?
    private var outputBuffer = Data()
    private var sessionID: String?
    private var failureText = ""
    private var streamedTextDuringRun = false
    private var sessionNotFoundDuringRun = false

    init(agentID: String, executablePath: String, context: ConversationContext) {
        self.agentID = agentID
        self.executablePath = executablePath
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
                self.onEvent?(.failed(agentID, "Agent 2 is still responding."))
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
