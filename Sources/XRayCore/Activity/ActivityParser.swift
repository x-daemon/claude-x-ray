import Foundation

/// Reconstructs activity (prompts, thinking, tool calls and results, context
/// updates, hooks...) from Claude Code transcript lines.
///
/// Like `TranscriptParser`, it is lenient: unknown entry and block types are
/// skipped. Entries that carry personal account data (`session_context`,
/// `credential_org`) are never read.
public enum ActivityParser {
    /// Maximum length of stored detail text (prompts, outputs, commands).
    public static let detailLimit = 2_000

    public static func parse(
        line: Data,
        fallbackSessionID: String = "unknown",
        fallbackProject: String = "unknown"
    ) -> [ActivityItem] {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let entry = object as? [String: Any],
              let type = entry["type"] as? String,
              let timestampString = entry["timestamp"] as? String,
              let timestamp = TranscriptParser.parseDate(timestampString) else { return [] }

        let base = Base(
            uuid: (entry["uuid"] as? String) ?? "\(type)|\(timestampString)",
            timestamp: timestamp,
            sessionID: (entry["sessionId"] as? String) ?? fallbackSessionID,
            projectPath: (entry["cwd"] as? String) ?? fallbackProject,
            gitBranch: (entry["gitBranch"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            isSidechain: (entry["isSidechain"] as? Bool) ?? false
        )

        switch type {
        case "user": return parseUser(entry, base)
        case "assistant": return parseAssistant(entry, base)
        case "attachment": return parseAttachment(entry, base)
        case "system": return parseSystem(entry, base)
        case "queue-operation": return parseQueue(entry, base, timestampString: timestampString)
        default: return []
        }
    }

    // MARK: - Entries

    struct Base {
        let uuid: String
        let timestamp: Date
        let sessionID: String
        let projectPath: String
        let gitBranch: String?
        let isSidechain: Bool

        func item(_ index: Int, _ kind: ActivityKind, title: String, detail: String? = nil, isError: Bool = false) -> ActivityItem {
            ActivityItem(
                id: "\(uuid)#\(index)",
                kind: kind,
                timestamp: timestamp,
                sessionID: sessionID,
                projectPath: projectPath,
                gitBranch: gitBranch,
                isSidechain: isSidechain,
                title: title,
                detail: detail,
                isError: isError
            )
        }
    }

    private static func parseUser(_ entry: [String: Any], _ base: Base) -> [ActivityItem] {
        guard let message = entry["message"] as? [String: Any] else { return [] }
        let isMeta = (entry["isMeta"] as? Bool) ?? false

        if (entry["isCompactSummary"] as? Bool) == true {
            let text = textContent(message["content"])
            return [base.item(0, .compact, title: "Сводка после сжатия контекста", detail: Snippet.truncate(text, detailLimit))]
        }

        if let text = message["content"] as? String {
            return isMeta ? [] : userText(text, base, index: 0).map { [$0] } ?? []
        }

        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        var items: [ActivityItem] = []
        for (index, block) in blocks.enumerated() {
            let blockType = (block["type"] as? String) ?? ""
            switch blockType {
            case "text":
                guard !isMeta, let text = block["text"] as? String, let item = userText(text, base, index: index) else { continue }
                items.append(item)
            case "image":
                if !isMeta { items.append(base.item(index, .prompt, title: "Изображение")) }
            case "tool_result":
                items.append(toolResult(block, entry: entry, base: base, index: index))
            default:
                continue
            }
        }
        return items
    }

    /// Classifies user text: interruption, slash command, command output or a plain prompt.
    private static func userText(_ text: String, _ base: Base, index: Int) -> ActivityItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("[Request interrupted") {
            return base.item(index, .interrupted, title: "Прервано пользователем", detail: trimmed)
        }
        if let name = tag("command-name", in: trimmed) {
            let args = tag("command-args", in: trimmed) ?? ""
            return base.item(index, .prompt, title: "Команда \(name) \(args)".trimmingCharacters(in: .whitespaces), detail: args.isEmpty ? nil : args)
        }
        if let output = tag("local-command-stdout", in: trimmed) {
            return base.item(index, .note, title: "Вывод команды: " + Snippet.firstLine(output, 100), detail: Snippet.truncate(output, detailLimit))
        }
        if let command = tag("bash-input", in: trimmed) {
            return base.item(index, .prompt, title: "! " + Snippet.firstLine(command, 100), detail: command)
        }
        if trimmed.hasPrefix("<bash-stdout>") || trimmed.hasPrefix("<bash-stderr>") {
            let output = tag("bash-stdout", in: trimmed) ?? tag("bash-stderr", in: trimmed) ?? ""
            return base.item(index, .note, title: "Вывод оболочки: " + Snippet.firstLine(output, 100), detail: Snippet.truncate(output, detailLimit))
        }
        return base.item(index, .prompt, title: Snippet.firstLine(trimmed, 160), detail: Snippet.truncate(trimmed, detailLimit))
    }

    private static func toolResult(_ block: [String: Any], entry: [String: Any], base: Base, index: Int) -> ActivityItem {
        let text = textContent(block["content"])
        let images = imageCount(block["content"])
        let isError = (block["is_error"] as? Bool) ?? false
        let result = entry["toolUseResult"] as? [String: Any]

        var title = text.isEmpty ? (images > 0 ? "Изображение" : "Пустой результат") : Snippet.firstLine(text, 140)
        if (result?["interrupted"] as? Bool) == true {
            title = "Прервано: " + title
        }
        var detail = Snippet.truncate(text, detailLimit)
        if let stderr = result?["stderr"] as? String, !stderr.isEmpty, !text.contains(stderr.prefix(80)) {
            detail += "\n[stderr] " + Snippet.truncate(stderr, 600)
        }

        var item = base.item(index, .toolResult, title: title, detail: detail.isEmpty ? nil : detail, isError: isError)
        item.toolUseID = block["tool_use_id"] as? String
        item.outputBytes = text.utf8.count
        item.permission = permissionLabel(entry["permissionDecision"])

        if let patch = result?["structuredPatch"] as? [[String: Any]] {
            var added = 0
            var removed = 0
            for hunk in patch {
                for line in hunk["lines"] as? [String] ?? [] {
                    if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
                }
            }
            item.linesAdded = added
            item.linesRemoved = removed
        }
        if let kind = result?["type"] as? String, kind == "create", item.linesAdded == nil,
           let content = result?["content"] as? String {
            item.linesAdded = content.split(separator: "\n", omittingEmptySubsequences: false).count
        }
        return item
    }

    private static func parseAssistant(_ entry: [String: Any], _ base: Base) -> [ActivityItem] {
        guard let message = entry["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return [] }
        let model = message["model"] as? String
        let messageID = message["id"] as? String
        let stopReason = message["stop_reason"] as? String

        if model == "<synthetic>" {
            let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            guard !text.isEmpty else { return [] }
            return [base.item(0, .apiError, title: Snippet.firstLine(text, 160), detail: Snippet.truncate(text, detailLimit), isError: true)]
        }

        var items: [ActivityItem] = []
        for (index, block) in blocks.enumerated() {
            var item: ActivityItem
            let blockType = (block["type"] as? String) ?? ""
            switch blockType {
            case "thinking", "redacted_thinking":
                let text = (block["thinking"] as? String) ?? ""
                item = base.item(index, .thinking, title: text.isEmpty ? "Размышление" : Snippet.firstLine(text, 140), detail: text.isEmpty ? nil : Snippet.truncate(text, detailLimit))
                item.thinkingMs = entry["thinkingDurationMs"] as? Int
            case "text":
                let text = (block["text"] as? String) ?? ""
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                item = base.item(index, .reply, title: Snippet.firstLine(text, 160), detail: Snippet.truncate(text, detailLimit))
            case "tool_use", "server_tool_use":
                let name = (block["name"] as? String) ?? "tool"
                let input = (block["input"] as? [String: Any]) ?? [:]
                let description = ToolDescriber.describe(name: name, input: input)
                item = base.item(index, .toolCall, title: description.title, detail: description.detail)
                item.toolUseID = block["id"] as? String
                item.toolName = name
                item.target = description.target
                item.fileAction = description.fileAction
                item.inputStreamMs = entry["toolInputStreamMs"] as? Int
            case let type where type.hasSuffix("_tool_result"):
                let text = textContent(block["content"])
                item = base.item(index, .toolResult, title: text.isEmpty ? type : Snippet.firstLine(text, 140), detail: text.isEmpty ? nil : Snippet.truncate(text, detailLimit))
                item.toolUseID = block["tool_use_id"] as? String
                item.outputBytes = text.utf8.count
            default:
                continue
            }
            item.messageID = messageID
            item.model = model
            item.requestedModel = entry["requestedModel"] as? String
            item.stopReason = stopReason
            item.effort = (entry["perTurnEffort"] as? String) ?? (entry["effort"] as? String)
            item.attributionSkill = entry["attributionSkill"] as? String
            items.append(item)
        }
        return items
    }

    private static func parseAttachment(_ entry: [String: Any], _ base: Base) -> [ActivityItem] {
        guard let attachment = entry["attachment"] as? [String: Any],
              let type = attachment["type"] as? String else { return [] }
        func strings(_ key: String) -> [String] { (attachment[key] as? [Any])?.compactMap { $0 as? String } ?? [] }
        func chars(_ key: String) -> Int {
            if let text = attachment[key] as? String { return text.count }
            return strings(key).reduce(0) { $0 + $1.count }
        }

        var item: ActivityItem
        switch type {
        case "deferred_tools_delta":
            let added = strings("addedNames")
            let removed = strings("removedNames")
            let pending = strings("pendingMcpServers")
            let failed = strings("failedMcpServers")
            let needsAuth = strings("needsAuthMcpServers")
            let servers = Set(added.compactMap(ToolDescriber.mcpServer(of:))).sorted()
            var title = "Инструменты: +\(added.count)"
            if !removed.isEmpty { title += " −\(removed.count)" }
            if !servers.isEmpty { title += " · MCP: \(servers.joined(separator: ", "))" }
            var notes: [String] = []
            if !failed.isEmpty { notes.append("Не подключились: \(failed.joined(separator: ", "))") }
            if !needsAuth.isEmpty { notes.append("Нужна авторизация: \(needsAuth.joined(separator: ", "))") }
            if !pending.isEmpty { notes.append("Подключаются: \(pending.joined(separator: ", "))") }
            item = base.item(0, .context, title: title, detail: notes.isEmpty ? nil : notes.joined(separator: "\n"), isError: !failed.isEmpty)
            item.context = .tools(added: added, removed: removed, pendingMCP: pending, failedMCP: failed, needsAuthMCP: needsAuth, listingChars: chars("addedLines"))
        case "skill_listing":
            let names = strings("names")
            let count = (attachment["skillCount"] as? Int) ?? names.count
            item = base.item(0, .context, title: "Скиллы в контексте: \(count)", detail: names.joined(separator: ", "))
            item.context = .skills(names: names, count: count, listingChars: chars("content"))
        case "mcp_instructions_delta":
            let added = strings("addedNames")
            item = base.item(0, .context, title: "Инструкции MCP: \(added.joined(separator: ", "))")
            item.context = .mcpInstructions(added: added, removed: strings("removedNames"), chars: chars("addedBlocks"))
        case "agent_listing_delta":
            let added = strings("addedTypes")
            item = base.item(0, .context, title: "Типы субагентов: \(added.joined(separator: ", "))")
            item.context = .agents(added: added, removed: strings("removedTypes"), chars: chars("addedLines"))
        case "prompt_snapshot":
            let parts = strings("systemPrompt")
            let total = parts.isEmpty ? chars("systemPrompt") : parts.reduce(0) { $0 + $1.count }
            item = base.item(0, .context, title: "Системный промпт: \(total) символов (≈\(Fmt.tokens(total / 4)) токенов)")
            item.context = .systemPrompt(chars: total, parts: max(parts.count, 1))
        case "environment":
            let snapshot = attachment["snapshot"] as? [String: Any] ?? [:]
            var values: [String: String] = [:]
            for (key, value) in snapshot {
                switch value {
                case let text as String: values[key] = text
                case let flag as Bool: values[key] = flag ? "да" : "нет"
                case let number as NSNumber: values[key] = number.stringValue
                case let list as [Any]: values[key] = list.compactMap { $0 as? String }.joined(separator: ", ")
                default: continue
                }
            }
            let summary = [values["platform"], values["shell"], values["osVersion"]].compactMap { $0 }.joined(separator: " · ")
            item = base.item(0, .context, title: "Окружение: \(summary)", detail: values["workingDirectory"])
            item.context = .environment(values)
        case "model":
            let identity = attachment["identity"] as? [String: Any] ?? [:]
            let id = (identity["modelId"] as? String) ?? "?"
            let name = identity["marketingName"] as? String
            item = base.item(0, .context, title: "Модель: \(name ?? id)", detail: id)
            item.context = .model(id: id, name: name, knowledgeCutoff: identity["knowledgeCutoff"] as? String)
        case "auto_mode":
            var flags: [String: String] = [:]
            for (key, value) in attachment where key != "type" {
                if let flag = value as? Bool { flags[key] = flag ? "да" : "нет" } else if let text = value as? String { flags[key] = text }
            }
            item = base.item(0, .context, title: "Auto mode включён")
            item.context = .autoMode(flags)
        case "command_permissions":
            let allowed = strings("allowedTools")
            item = base.item(0, .context, title: "Разрешённые правила: \(allowed.count)", detail: allowed.joined(separator: "\n"))
            item.context = .permissions(allowed: allowed)
        case "edited_text_file":
            let path = (attachment["filename"] as? String) ?? "?"
            item = base.item(0, .context, title: "Файл изменён вне Claude: \(Snippet.shortPath(path))", detail: path)
            item.context = .editedFile(path: path)
        case "task_reminder":
            let count = (attachment["itemCount"] as? Int) ?? 0
            item = base.item(0, .context, title: "Список задач: \(count)")
            item.context = .tasks(count: count)
        case "remote_session_change":
            let commit = attachment["commit"] as? String
            let pr = attachment["pr"] as? String
            let url = attachment["url"] as? String
            var kinds: [String] = []
            if commit != nil { kinds.append("коммит") }
            if pr != nil { kinds.append("PR") }
            let details: [String] = [commit, pr, url].compactMap { $0 }
            item = base.item(0, .context, title: "Изменения сессии: " + (kinds.isEmpty ? "ссылка" : kinds.joined(separator: ", ")), detail: details.joined(separator: "\n"))
            item.context = .remoteChange(commit: commit, pullRequest: pr, url: url)
        case "queued_command":
            let prompt = (attachment["prompt"] as? String) ?? ""
            item = base.item(0, .queued, title: "Передано модели: " + Snippet.firstLine(prompt, 140), detail: Snippet.truncate(prompt, detailLimit))
        case let hook where hook.hasPrefix("hook"):
            let name = (attachment["hookName"] as? String) ?? hook
            let content = (attachment["content"] as? String) ?? (attachment["stdout"] as? String)
            item = base.item(0, .hook, title: "Хук: \(name)", detail: content.map { Snippet.truncate($0, detailLimit) }, isError: hook.contains("error"))
        default:
            // date, silent reminders, deferred tool records; session_context and credential_org hold account data.
            return []
        }
        return [item]
    }

    private static func parseSystem(_ entry: [String: Any], _ base: Base) -> [ActivityItem] {
        let subtype = (entry["subtype"] as? String) ?? ""
        if subtype == "stop_hook_summary" {
            let count = (entry["hookCount"] as? Int) ?? 0
            let errors = (entry["hookErrors"] as? [Any])?.count ?? 0
            let prevented = (entry["preventedContinuation"] as? Bool) ?? false
            var title = "Хуки Stop: \(count)"
            if errors > 0 { title += ", ошибок: \(errors)" }
            if prevented { title += " · остановили продолжение" }
            return [base.item(0, .hook, title: title, isError: errors > 0)]
        }
        if subtype.contains("compact") {
            let metadata = entry["compactMetadata"] as? [String: Any]
            let trigger = (metadata?["trigger"] as? String).map { $0 == "auto" ? "автоматически" : "вручную" } ?? ""
            let pre = (metadata?["preTokens"] as? Int).map { " · было \(Fmt.tokens($0)) токенов" } ?? ""
            return [base.item(0, .compact, title: "Контекст сжат \(trigger)\(pre)".replacingOccurrences(of: "  ", with: " "))]
        }
        if let content = entry["content"] as? String, !content.isEmpty {
            let isError = (entry["level"] as? String) == "error"
            return [base.item(0, isError ? .apiError : .note, title: Snippet.firstLine(content, 160), detail: Snippet.truncate(content, detailLimit), isError: isError)]
        }
        return []
    }

    private static func parseQueue(_ entry: [String: Any], _ base: Base, timestampString: String) -> [ActivityItem] {
        let operation = (entry["operation"] as? String) ?? ""
        let content = (entry["content"] as? String) ?? ""
        let id = "queue|\(base.sessionID)|\(timestampString)|\(operation)"
        let make = { (title: String) -> ActivityItem in
            ActivityItem(id: id, kind: .queued, timestamp: base.timestamp, sessionID: base.sessionID, projectPath: base.projectPath, title: title, detail: content.isEmpty ? nil : Snippet.truncate(content, detailLimit))
        }
        switch operation {
        case "enqueue": return content.isEmpty ? [] : [make("В очереди: " + Snippet.firstLine(content, 140))]
        case "remove": return [make("Убрано из очереди" + (content.isEmpty ? "" : ": " + Snippet.firstLine(content, 120)))]
        default: return []
        }
    }

    // MARK: - Helpers

    /// Text of a `content` field that is either a string or a list of blocks.
    static func textContent(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            if let text = block["text"] as? String { return text }
            if let nested = block["content"] { return textContent(nested) }
            return nil
        }.joined(separator: "\n")
    }

    static func imageCount(_ content: Any?) -> Int {
        (content as? [[String: Any]])?.filter { ($0["type"] as? String) == "image" }.count ?? 0
    }

    /// Value of `<name>...</name>` in text.
    static func tag(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(name)>"),
              let end = text.range(of: "</\(name)>", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `{"decision":"accept","source":"config","reasonType":"rule","ruleSource":"cliArg"}` -> "accept · правило (cliArg)".
    static func permissionLabel(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let decision = value as? [String: Any] else { return nil }
        let verdict = (decision["decision"] as? String) ?? "?"
        let reasonType = (decision["reasonType"] as? String) ?? ""
        var reason: String
        switch reasonType {
        case "rule": reason = "правило"
        case "classifier": reason = "классификатор auto mode"
        case "user", "userApproval": reason = "пользователь"
        case "": reason = (decision["source"] as? String) ?? ""
        default: reason = reasonType
        }
        if let rule = decision["ruleSource"] as? String { reason += " (\(rule))" }
        return reason.isEmpty ? verdict : "\(verdict) · \(reason)"
    }
}
