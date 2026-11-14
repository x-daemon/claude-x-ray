import Foundation

/// Turns a tool call's name and input into a readable one-line summary.
public enum ToolDescriber {
    public struct Description: Hashable, Sendable {
        public var title: String
        public var detail: String?
        public var target: String?
        public var fileAction: FileAction?

        public init(title: String, detail: String? = nil, target: String? = nil, fileAction: FileAction? = nil) {
            self.title = title
            self.detail = detail
            self.target = target
            self.fileAction = fileAction
        }
    }

    /// Category used to group tools in charts and the flow map.
    public enum Category: String, Sendable, CaseIterable {
        case shell = "Оболочка"
        case read = "Чтение"
        case write = "Изменение файлов"
        case search = "Поиск"
        case web = "Веб"
        case agent = "Субагенты"
        case skill = "Скиллы"
        case mcp = "MCP"
        case planning = "Планирование"
        case other = "Другое"
    }

    public static func mcpServer(of toolName: String) -> String? {
        guard toolName.hasPrefix("mcp__") else { return nil }
        let parts = toolName.components(separatedBy: "__")
        return parts.count >= 2 ? parts[1] : nil
    }

    public static func mcpTool(of toolName: String) -> String? {
        guard toolName.hasPrefix("mcp__") else { return nil }
        let parts = toolName.components(separatedBy: "__")
        return parts.count >= 3 ? parts[2...].joined(separator: "__") : nil
    }

    /// Readable tool name: `mcp__Linear__list_issues` -> `MCP Linear · list_issues`.
    public static func displayName(for toolName: String) -> String {
        guard let server = mcpServer(of: toolName) else { return toolName }
        return "MCP \(server) · \(mcpTool(of: toolName) ?? toolName)"
    }

    public static func category(of toolName: String) -> Category {
        if toolName.hasPrefix("mcp__") { return .mcp }
        switch toolName {
        case "Bash", "BashOutput", "KillShell", "KillBash", "Monitor": return .shell
        case "Read", "NotebookRead", "ReadMcpResourceTool", "ListMcpResourcesTool": return .read
        case "Write", "Edit", "MultiEdit", "NotebookEdit": return .write
        case "Grep", "Glob", "LS", "ToolSearch": return .search
        case "WebFetch", "WebSearch", "web_search", "web_fetch": return .web
        case "Task", "Agent", "SendMessage": return .agent
        case "Skill": return .skill
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "ExitPlanMode", "EnterPlanMode", "AskUserQuestion":
            return .planning
        default: return .other
        }
    }

    public static func describe(name: String, input: [String: Any]) -> Description {
        func s(_ key: String) -> String? {
            (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }

        switch name {
        case "Bash":
            let command = s("command") ?? ""
            var detail = command.isEmpty ? nil : "$ " + Snippet.truncate(command, 1_500)
            if let description = s("description") {
                detail = description + (detail.map { "\n" + $0 } ?? "")
            }
            if input["run_in_background"] as? Bool == true {
                detail = (detail ?? "") + "\n(в фоне)"
            }
            return Description(title: "Bash: " + Snippet.firstLine(command, 110), detail: detail)

        case "BashOutput", "KillShell", "KillBash":
            let shell = s("bash_id") ?? s("shell_id") ?? ""
            return Description(title: "\(name) \(shell)".trimmingCharacters(in: .whitespaces))

        case "Read":
            let path = s("file_path") ?? ""
            var parts: [String] = []
            if let offset = input["offset"] as? Int { parts.append("с строки \(offset)") }
            if let limit = input["limit"] as? Int { parts.append("\(limit) строк") }
            if let pages = s("pages") { parts.append("страницы \(pages)") }
            return Description(
                title: "Read " + Snippet.shortPath(path) + (parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"),
                detail: path, target: path, fileAction: .read
            )

        case "Write":
            let path = s("file_path") ?? ""
            let content = input["content"] as? String ?? ""
            let lines = content.isEmpty ? 0 : content.split(separator: "\n", omittingEmptySubsequences: false).count
            return Description(
                title: "Write \(Snippet.shortPath(path)) · \(lines) строк",
                detail: "\(path)\n\(content.utf8.count) байт",
                target: path, fileAction: .write
            )

        case "Edit":
            let path = s("file_path") ?? ""
            let old = input["old_string"] as? String ?? ""
            let new = input["new_string"] as? String ?? ""
            let all = input["replace_all"] as? Bool == true ? " · все вхождения" : ""
            return Description(
                title: "Edit \(Snippet.shortPath(path))\(all)",
                detail: "\(path)\n− \(Snippet.truncate(old, 400))\n+ \(Snippet.truncate(new, 400))",
                target: path, fileAction: .edit
            )

        case "MultiEdit":
            let path = s("file_path") ?? ""
            let count = (input["edits"] as? [Any])?.count ?? 0
            return Description(title: "MultiEdit \(Snippet.shortPath(path)) · \(count) правок", detail: path, target: path, fileAction: .edit)

        case "NotebookEdit":
            let path = s("notebook_path") ?? ""
            return Description(title: "NotebookEdit \(Snippet.shortPath(path))", detail: path, target: path, fileAction: .edit)

        case "Grep":
            let pattern = s("pattern") ?? ""
            let scope = [s("path").map(Snippet.shortPath), s("glob"), s("type")].compactMap { $0 }.joined(separator: ", ")
            return Description(
                title: "Grep «\(Snippet.firstLine(pattern, 60))»" + (scope.isEmpty ? "" : " в \(scope)"),
                detail: Snippet.compactJSON(input), target: s("path")
            )

        case "Glob":
            let pattern = s("pattern") ?? ""
            return Description(title: "Glob \(pattern)" + (s("path").map { " в \(Snippet.shortPath($0))" } ?? ""), detail: Snippet.compactJSON(input), target: s("path"))

        case "LS":
            return Description(title: "LS \(Snippet.shortPath(s("path") ?? ""))", target: s("path"))

        case "WebFetch", "web_fetch":
            let url = s("url") ?? ""
            let host = URL(string: url)?.host ?? url
            return Description(title: "WebFetch \(host)", detail: [url, s("prompt")].compactMap { $0 }.joined(separator: "\n"), target: url)

        case "WebSearch", "web_search":
            let query = s("query") ?? ""
            return Description(title: "WebSearch «\(Snippet.firstLine(query, 80))»", detail: query)

        case "Task", "Agent":
            let description = s("description") ?? "задача"
            let type = s("subagent_type").map { " (\($0))" } ?? ""
            return Description(
                title: "Субагент\(type): \(Snippet.firstLine(description, 90))",
                detail: s("prompt").map { Snippet.truncate($0, 1_500) },
                target: s("subagent_type")
            )

        case "Skill":
            let skill = s("skill") ?? s("command") ?? "?"
            return Description(title: "Skill \(skill)", detail: s("args"), target: skill)

        case "TodoWrite":
            let todos = input["todos"] as? [[String: Any]] ?? []
            let lines = todos.map { todo -> String in
                let status = todo["status"] as? String ?? ""
                let mark = status == "completed" ? "☑" : status == "in_progress" ? "▶" : "☐"
                return "\(mark) \(todo["content"] as? String ?? "")"
            }
            return Description(title: "TodoWrite · \(todos.count) задач", detail: lines.joined(separator: "\n"))

        case "AskUserQuestion":
            let questions = (input["questions"] as? [[String: Any]] ?? []).compactMap { $0["question"] as? String }
            return Description(title: "Вопрос пользователю", detail: questions.joined(separator: "\n"))

        case "ExitPlanMode":
            return Description(title: "План готов", detail: s("plan").map { Snippet.truncate($0, 1_500) })

        case "ToolSearch":
            return Description(title: "ToolSearch «\(Snippet.firstLine(s("query") ?? "", 80))»", detail: Snippet.compactJSON(input))

        default:
            if let server = mcpServer(of: name) {
                let tool = mcpTool(of: name) ?? name
                let key = ["query", "q", "url", "path", "file_path", "repo", "name", "title", "id"].lazy.compactMap { s($0) }.first
                return Description(
                    title: "MCP \(server) · \(tool)" + (key.map { ": \(Snippet.firstLine($0, 70))" } ?? ""),
                    detail: Snippet.compactJSON(input),
                    target: server
                )
            }
            return Description(title: name, detail: input.isEmpty ? nil : Snippet.compactJSON(input))
        }
    }
}

/// String helpers for summaries.
public enum Snippet {
    public static func truncate(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    /// First non-empty line, trimmed and truncated.
    public static func firstLine(_ text: String, _ limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let extra = text.contains(where: \.isNewline) && trimmed.count <= limit ? " …" : ""
        return truncate(trimmed, limit) + extra
    }

    /// Last two path components: `/Users/me/app/Sources/Main.swift` -> `Sources/Main.swift`.
    public static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count > 2 else { return path }
        return parts.suffix(2).joined(separator: "/")
    }

    public static func compactJSON(_ object: Any, limit: Int = 800) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return truncate(text, limit)
    }
}
