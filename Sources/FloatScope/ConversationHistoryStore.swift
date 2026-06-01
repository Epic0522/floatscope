import Foundation

struct ConversationHistoryEntry: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var codexThreadID: String?
    var opencodeSessionID: String?
    var updatedAt: Date
    var messageCount: Int
    var preview: String

    var agentCount: Int {
        [codexThreadID, opencodeSessionID].compactMap(\.self).count
    }
}

enum ConversationHistoryStore {
    private struct ParsedContent {
        var text: String
        var attachments: [ChatAttachment]
    }

    static func list(conversationRoot: String, agents: [AgentRuntimeConfig]) -> [ConversationHistoryEntry] {
        let root = normalized(conversationRoot)
        return (
            codexEntries(conversationRoot: root, agentID: agents.first?.id ?? "agent1")
                + opencodeEntries(conversationRoot: root, agentID: agents.dropFirst().first?.id ?? "agent2")
        )
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func loadMessages(for entry: ConversationHistoryEntry, agents: [AgentRuntimeConfig]) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        if let threadID = entry.codexThreadID {
            messages += codexMessages(threadID: threadID, agentID: agents.first?.id ?? "agent1")
        }
        if let sessionID = entry.opencodeSessionID {
            messages += opencodeMessages(sessionID: sessionID, agentID: agents.dropFirst().first?.id ?? "agent2")
        }
        return dedupe(messages.sorted { $0.createdAt < $1.createdAt })
    }

    private static func codexEntries(conversationRoot: String, agentID: String) -> [ConversationHistoryEntry] {
        let index = codexIndex()
        return codexSessionFiles().compactMap { url in
            guard let meta = codexMeta(from: url),
                  normalized(meta.cwd) == conversationRoot else {
                return nil
            }
            let title = index[meta.id]?.title ?? timestampTitle(from: meta.timestamp) ?? meta.id
            let updatedAt = index[meta.id]?.updatedAt ?? meta.timestamp
            let messages = codexMessages(from: url, agentID: agentID)
            return ConversationHistoryEntry(
                id: "codex:\(meta.id)",
                title: title,
                codexThreadID: meta.id,
                opencodeSessionID: nil,
                updatedAt: updatedAt,
                messageCount: messages.count,
                preview: messages.last?.text ?? ""
            )
        }
    }

    private static func opencodeEntries(conversationRoot: String, agentID: String) -> [ConversationHistoryEntry] {
        let sql = """
        select s.id, s.title, s.time_updated, count(distinct m.id) as message_count
        from session s
        left join message m on m.session_id = s.id
        where s.directory = '\(escapeSQL(conversationRoot))'
        group by s.id
        order by s.time_updated desc;
        """
        return runSQLiteJSON(sql).compactMap { row in
            guard let sessionID = row["id"] as? String,
                  let updatedMs = row["time_updated"] as? Double ?? (row["time_updated"] as? Int).map(Double.init) else {
                return nil
            }
            let title = (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sessionID
            let preview = latestOpencodeText(sessionID: sessionID) ?? ""
            return ConversationHistoryEntry(
                id: "opencode:\(sessionID)",
                title: title,
                codexThreadID: nil,
                opencodeSessionID: sessionID,
                updatedAt: Date(timeIntervalSince1970: updatedMs / 1000),
                messageCount: row["message_count"] as? Int ?? 0,
                preview: preview
            )
        }
    }

    private static func codexMessages(threadID: String, agentID: String) -> [ChatMessage] {
        guard let url = codexSessionFiles().first(where: { $0.lastPathComponent.contains(threadID) }) else {
            return []
        }
        return codexMessages(from: url, agentID: agentID)
    }

    private static func codexMessages(from url: URL, agentID: String) -> [ChatMessage] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return raw.split(separator: "\n").compactMap { line -> ChatMessage? in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "response_item",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  let role = payload["role"] as? String else {
                return nil
            }

            let content = extractCodexContent(from: payload, role: role)
            guard (!content.text.isEmpty || !content.attachments.isEmpty),
                  let timestamp = date(from: object["timestamp"] as? String) else {
                return nil
            }

            if role == "user" {
                return ChatMessage(role: .user, text: content.text, attachments: content.attachments, createdAt: timestamp)
            }
            if role == "assistant" {
                return ChatMessage(role: .agent(agentID), text: content.text, attachments: content.attachments, createdAt: timestamp)
            }
            return nil
        }
    }

    private static func opencodeMessages(sessionID: String, agentID: String) -> [ChatMessage] {
        let messageSQL = """
        select id as message_id,
               time_created,
               json_extract(data, '$.role') as role
        from message
        where session_id = '\(escapeSQL(sessionID))'
        order by time_created desc
        limit 80;
        """
        var order: [String] = []
        var grouped: [String: (createdAt: Date, role: String, texts: [String], attachments: [ChatAttachment])] = [:]
        for row in runSQLiteJSON(messageSQL).reversed() {
            guard let createdMs = row["time_created"] as? Double ?? (row["time_created"] as? Int).map(Double.init),
                  let messageID = row["message_id"] as? String,
                  let role = row["role"] as? String else {
                continue
            }
            order.append(messageID)
            grouped[messageID] = (Date(timeIntervalSince1970: createdMs / 1000), role, [], [])
        }

        let ids = order.map { "'\(escapeSQL($0))'" }.joined(separator: ",")
        guard !ids.isEmpty else { return [] }

        let textSQL = """
        select message_id,
               json_extract(data, '$.text') as text
        from part
        where session_id = '\(escapeSQL(sessionID))'
          and message_id in (\(ids))
          and json_extract(data, '$.type') = 'text'
        order by time_created;
        """
        for row in runSQLiteJSON(textSQL) {
            guard let messageID = row["message_id"] as? String,
                  let text = row["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            grouped[messageID]?.texts.append(text)
        }

        let fileSQL = """
        select message_id,
               json_extract(data, '$.filename') as filename,
               json_extract(data, '$.mime') as mime,
               json_extract(data, '$.path') as path
        from part
        where session_id = '\(escapeSQL(sessionID))'
          and message_id in (\(ids))
          and json_extract(data, '$.type') = 'file'
          and json_extract(data, '$.path') is not null
        order by time_created desc
        limit 12;
        """
        for row in runSQLiteJSON(fileSQL) {
            guard let messageID = row["message_id"] as? String,
                  let path = row["path"] as? String,
                  FileManager.default.fileExists(atPath: path) else {
                continue
            }
            let url = URL(fileURLWithPath: path)
            let filename = row["filename"] as? String ?? url.lastPathComponent
            let mimeType = row["mime"] as? String ?? mimeType(for: url)
            grouped[messageID]?.attachments.append(ChatAttachment(path: path, filename: filename, mimeType: mimeType))
        }

        return order.compactMap { id in
            guard let item = grouped[id] else { return nil }
            let text = item.texts.joined(separator: "\n\n")
            guard !text.isEmpty || !item.attachments.isEmpty else { return nil }
            if item.role == "user" {
                return ChatMessage(role: .user, text: text, attachments: item.attachments, createdAt: item.createdAt)
            }
            if item.role == "assistant" {
                return ChatMessage(role: .agent(agentID), text: text, attachments: item.attachments, createdAt: item.createdAt)
            }
            return nil
        }
    }

    private static func latestOpencodeText(sessionID: String) -> String? {
        let sql = """
        select coalesce(json_extract(p.data, '$.text'), '') as text
        from part p
        join message m on m.id = p.message_id
        where p.session_id = '\(escapeSQL(sessionID))'
          and json_extract(p.data, '$.type') = 'text'
          and coalesce(json_extract(p.data, '$.text'), '') != ''
        order by p.time_created desc
        limit 1;
        """
        return runSQLiteJSON(sql).first?["text"] as? String
    }

    private static func extractCodexContent(from payload: [String: Any], role: String) -> ParsedContent {
        guard let content = payload["content"] as? [[String: Any]] else {
            return ParsedContent(text: "", attachments: [])
        }
        var attachments: [ChatAttachment] = []
        let pieces = content.compactMap { item -> String? in
            let type = item["type"] as? String
            if type == "localImage",
               let path = item["path"] as? String {
                let url = URL(fileURLWithPath: path)
                attachments.append(ChatAttachment(path: path, filename: url.lastPathComponent, mimeType: mimeType(for: url)))
                return nil
            }
            guard type == "input_text" || type == "output_text" else {
                return nil
            }
            let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if role == "user", shouldHideCodexInput(text) {
                return nil
            }
            return text.isEmpty ? nil : text
        }
        return ParsedContent(text: pieces.joined(separator: "\n\n"), attachments: attachments)
    }

    private static func shouldHideCodexInput(_ text: String) -> Bool {
        text.hasPrefix("# AGENTS.md instructions")
            || text.hasPrefix("<environment_context>")
            || text.hasPrefix("<permissions instructions>")
            || text.hasPrefix("<skills_instructions>")
    }

    private static func codexMeta(from url: URL) -> (id: String, cwd: String, timestamp: Date)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let line = String(data: handle.availableData.prefix(120_000), encoding: .utf8)?
            .split(separator: "\n")
            .first,
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["type"] as? String == "session_meta",
            let payload = object["payload"] as? [String: Any],
            let id = payload["id"] as? String,
            let cwd = payload["cwd"] as? String,
            let timestamp = date(from: payload["timestamp"] as? String) else {
            return nil
        }
        return (id, cwd, timestamp)
    }

    private static func codexIndex() -> [String: (title: String, updatedAt: Date)] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("session_index.jsonl")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: (String, Date)] = [:]
        for line in raw.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String,
                  let title = object["thread_name"] as? String,
                  let updatedAt = date(from: object["updated_at"] as? String) else {
                continue
            }
            result[id] = (title, updatedAt)
        }
        return result
    }

    private static func codexSessionFiles() -> [URL] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
            return url
        }
    }

    private static func runSQLiteJSON(_ sql: String) -> [[String: Any]] {
        let dbURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local")
            .appendingPathComponent("share")
            .appendingPathComponent("opencode")
            .appendingPathComponent("opencode.db")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-json", dbURL.path, sql]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        guard process.terminationStatus == 0 else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    private static func attachment(fromOpenCodeFile object: [String: Any], fallbackName: String, remainingDataURLAttachments: inout Int) -> ChatAttachment? {
        let filename = object["filename"] as? String ?? fallbackName
        let mimeType = object["mime"] as? String
        if let path = object["path"] as? String,
           FileManager.default.fileExists(atPath: path) {
            return ChatAttachment(path: path, filename: URL(fileURLWithPath: path).lastPathComponent, mimeType: mimeType)
        }
        guard let url = object["url"] as? String,
              url.hasPrefix("data:") else {
            return nil
        }
        guard remainingDataURLAttachments > 0,
              url.count < 8_000_000,
              let attachment = writeDataURL(url, filename: filename, mimeType: mimeType) else {
            return nil
        }
        remainingDataURLAttachments -= 1
        return attachment
    }

    private static func writeDataURL(_ dataURL: String, filename: String, mimeType: String?) -> ChatAttachment? {
        guard let comma = dataURL.firstIndex(of: ",") else { return nil }
        let metadata = String(dataURL[dataURL.startIndex..<comma])
        let payload = String(dataURL[dataURL.index(after: comma)...])
        guard metadata.contains(";base64"),
              let data = Data(base64Encoded: payload) else {
            return nil
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("FloatScope")
            .appendingPathComponent("HistoryAttachments", isDirectory: true)
        let ext = URL(fileURLWithPath: filename).pathExtension.isEmpty ? extensionForMimeType(mimeType ?? metadata) : URL(fileURLWithPath: filename).pathExtension
        let output = directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: output, options: [.atomic])
            return ChatAttachment(path: output.path, filename: filename, mimeType: mimeType)
        } catch {
            return nil
        }
    }

    private static func extensionForMimeType(_ mimeType: String) -> String {
        if mimeType.contains("jpeg") { return "jpg" }
        if mimeType.contains("png") { return "png" }
        if mimeType.contains("gif") { return "gif" }
        if mimeType.contains("webp") { return "webp" }
        return "dat"
    }

    private static func mimeType(for url: URL) -> String? {
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

    private static func dedupe(_ messages: [ChatMessage]) -> [ChatMessage] {
        var result: [ChatMessage] = []
        for message in messages {
            if case .user = message.role,
               let previous = result.last,
               case .user = previous.role,
               previous.text == message.text,
               abs(previous.createdAt.timeIntervalSince(message.createdAt)) < 10 {
                continue
            }
            result.append(message)
        }
        return Array(result.suffix(80))
    }

    private static func timestampTitle(from date: Date) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }

    private static func date(from raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: raw) ?? plain.date(from: raw)
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func escapeSQL(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
