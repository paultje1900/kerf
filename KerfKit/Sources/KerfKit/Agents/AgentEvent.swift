import Foundation

/// A question an agent asks with options, as Claude Code's AskUserQuestion tool sends it.
public struct AgentQuestion: Equatable, Sendable, Identifiable {
    public struct Option: Equatable, Sendable, Identifiable {
        public var label: String
        public var description: String?
        public var id: String { label }
    }

    public var question: String
    public var header: String?
    public var options: [Option]
    public var multiSelect: Bool
    public var id: String { question }

    init?(_ value: JSONValue) {
        guard let question = value["question"]?.string else { return nil }
        self.question = question
        header = value["header"]?.string
        options = (value["options"]?.array ?? []).compactMap { option in
            option["label"]?.string.map { Option(label: $0, description: option["description"]?.string) }
        }
        multiSelect = value["multiSelect"]?.bool ?? false
    }
}

/// What a hook payload means, for Claude Code and Codex alike.
public enum AgentEvent: Equatable, Sendable {
    case permission(tool: String, input: JSONValue, suggestions: [JSONValue])
    /// AskUserQuestion, caught before it shows. `raw` is echoed back with the answers.
    case question([AgentQuestion], raw: JSONValue)
    case notification(type: String?, message: String?)
    /// The turn ended. Background subagents may still run and wake the thread again.
    case stop(lastMessage: String?, subagentsRunning: Bool)
    /// The turn ended on an API error: `rate_limit`, `overloaded`, `server_error` and the like.
    case stopFailed(error: String, details: String?)
    case subagentStarted(id: String)
    case subagentStopped(id: String)
    /// The tool asks you in its own window and Kerf can't answer for you there (VS Code's
    /// questions): the thread waits on you, and nothing waits on Kerf.
    case askedInApp(tool: String)
    /// A tool ran (or failed): a thread that waited on you has moved on.
    case toolFinished(tool: String)
    case sessionStart
    case sessionEnd
    case promptSubmitted(String?)
    case other(String)

    public init(_ payload: JSONValue) {
        let tool = payload["tool_name"]?.string ?? ""
        switch payload["hook_event_name"]?.string ?? "" {
        case "PermissionRequest":
            self = .permission(tool: tool, input: payload["tool_input"] ?? .null, suggestions: payload["permission_suggestions"]?.array ?? [])
        // VS Code asks in its own chat and takes no answers from a hook: Kerf only shows it waits.
        case "PreToolUse" where tool == "vscode_askQuestions":
            self = .askedInApp(tool: tool)
        case "PreToolUse" where tool == "AskUserQuestion":
            let raw = payload["tool_input"]?["questions"] ?? .array([])
            self = .question((raw.array ?? []).compactMap(AgentQuestion.init), raw: raw)
        case "Notification":
            self = .notification(type: payload["notification_type"]?.string, message: payload["message"]?.string)
        case "Stop":
            let running = (payload["background_tasks"]?.array ?? []).contains { $0["type"]?.string == "subagent" }
            self = .stop(lastMessage: payload["last_assistant_message"]?.string, subagentsRunning: running)
        case "StopFailure":
            self = .stopFailed(error: payload["error"]?.string ?? "unknown", details: payload["error_details"]?.string)
        case "SubagentStart":
            self = .subagentStarted(id: payload["agent_id"]?.string ?? "")
        case "SubagentStop":
            self = .subagentStopped(id: payload["agent_id"]?.string ?? "")
        case "PostToolUse", "PostToolUseFailure":
            self = .toolFinished(tool: tool)
        case "SessionStart": self = .sessionStart
        case "SessionEnd": self = .sessionEnd
        case "UserPromptSubmit": self = .promptSubmitted(payload["prompt"]?.string)
        case let name: self = .other(name)
        }
    }
}

/// Copilot sends camelCase fields unless its hooks are named in PascalCase, and some versions
/// leave out the event name. Kerf reads Claude Code's snake_case fields, so this fills them in.
public enum CopilotPayload {
    private static let renames = [
        "sessionId": "session_id", "toolName": "tool_name", "toolArgs": "tool_input", "toolInput": "tool_input",
        "transcriptPath": "transcript_path", "notificationType": "notification_type", "initialPrompt": "initial_prompt",
    ]

    public static func normalized(_ payload: JSONValue, event: String?) -> JSONValue {
        guard var object = payload.object else { return payload }
        for (from, to) in renames where object[to] == nil {
            if let value = object[from] { object[to] = value }
        }
        // Tool arguments can come as a JSON string.
        if case .string(let text)? = object["tool_input"], let parsed = JSONValue.parse(Data(text.utf8)), parsed.object != nil {
            object["tool_input"] = parsed
        }
        if object["hook_event_name"] == nil, let event { object["hook_event_name"] = .string(event) }
        return .object(object)
    }
}

extension JSONValue {
    public var sessionID: String { self["session_id"]?.string ?? "" }
    public var workingDirectory: String? { self["cwd"]?.string }
    public var transcriptPath: String? { self["transcript_path"]?.string }

    /// The repository's name, also from inside a worktree; nil for scratch folders.
    public var project: String? {
        workingDirectory.flatMap(ProjectName.of)
    }
}

/// A thread's title: the name Claude Code gave it or you renamed it to, else the first thing you
/// asked, on one line.
public enum ThreadTitle {
    public static func from(prompt: String) -> String? {
        let line = prompt.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        guard !line.isEmpty, !line.hasPrefix("<") else { return nil }
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    /// The first prompt in a Claude Code or Codex transcript (JSON lines).
    public static func fromTranscript(_ data: Data) -> String? {
        for line in data.split(separator: 0x0A).prefix(400) {
            guard let json = JSONValue.parse(Data(line)) else { continue }
            // Claude Code: {"type":"user","message":{"content":"…" or [{"type":"text","text":"…"}]}}
            if json["type"]?.string == "user", let content = json["message"]?["content"] {
                if let text = content.string ?? content.array?.compactMap({ $0["text"]?.string }).first, let title = from(prompt: text) {
                    return title
                }
            }
            // Codex: {"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"…"}]}}
            if let payload = json["payload"], payload["role"]?.string == "user",
               let text = payload["content"]?.array?.compactMap({ $0["text"]?.string }).first, let title = from(prompt: text) {
                return title
            }
        }
        return nil
    }

    /// The name at the end of a Claude Code transcript: yours after a rename, else its own. It
    /// writes both again every few turns, so the last stretch of the file holds them.
    public static func named(inTail data: Data) -> String? {
        var custom: String?
        var generated: String?
        for line in data.split(separator: 0x0A) where line.range(of: Data(#"-title""#.utf8)) != nil {
            guard let json = JSONValue.parse(Data(line)) else { continue }
            // {"type":"custom-title","customTitle":"…"} and {"type":"ai-title","aiTitle":"…"}
            switch json["type"]?.string {
            case "custom-title": custom = json["customTitle"]?.string.flatMap(from) ?? custom
            case "ai-title": generated = json["aiTitle"]?.string.flatMap(from) ?? generated
            default: break
            }
        }
        return custom ?? generated
    }

    /// A transcript's title: its name, else its first prompt.
    public static func fromTranscript(at url: URL) -> String? {
        named(inTail: RunningThreads.read(url, tail: true)) ?? fromTranscript(RunningThreads.read(url, tail: false))
    }
}

public enum ProjectName {
    /// Walks up to the git root. A worktree's .git file points into the main repository.
    public static func of(_ directory: String) -> String? {
        let files = FileManager.default
        var url = URL(fileURLWithPath: directory).standardizedFileURL
        for _ in 0..<12 {
            let git = url.appendingPathComponent(".git")
            var isFolder: ObjCBool = false
            if files.fileExists(atPath: git.path, isDirectory: &isFolder) {
                if !isFolder.boolValue, let link = try? String(contentsOf: git, encoding: .utf8),
                   let range = link.range(of: "/.git/worktrees/") {
                    let main = link.replacingOccurrences(of: "gitdir:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return URL(fileURLWithPath: String(main[..<main.range(of: "/.git/worktrees/")!.lowerBound])).lastPathComponent
                        .nilIfEmpty ?? (range.isEmpty ? nil : url.lastPathComponent)
                }
                return url.lastPathComponent
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        // Scratch and temp folders say nothing.
        if directory.contains("/.t3/") || directory.contains("/.p3code/") || directory.hasPrefix("/tmp") || directory.hasPrefix("/private/") { return nil }
        return URL(fileURLWithPath: directory).lastPathComponent
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// A tool call in a line or two, for the approval card.
public struct ToolSummary: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case command, edit, write, read, fetch, search, mcp(server: String), other
    }

    public var kind: Kind
    public var tool: String
    public var detail: String

    public init(tool: String, input: JSONValue, cwd: String? = nil) {
        self.tool = tool
        func path(_ key: String) -> String {
            let full = input[key]?.string ?? ""
            guard let cwd, full.hasPrefix(cwd + "/") else { return full }
            return String(full.dropFirst(cwd.count + 1))
        }
        switch tool {
        case "Bash", "bash", "shell", "exec_command", "local_shell":
            kind = .command
            if let command = input["command"]?.string { detail = command }
            else { detail = (input["command"]?.array ?? []).compactMap(\.string).joined(separator: " ") }
        case "Edit", "MultiEdit", "NotebookEdit", "apply_patch", "edit", "str_replace_editor":
            kind = .edit
            detail = path(input["file_path"] != nil ? "file_path" : input["path"] != nil ? "path" : "notebook_path")
        case "Write", "create":
            kind = .write
            detail = path(input["file_path"] != nil ? "file_path" : "path")
        case "Read", "view":
            kind = .read
            detail = path(input["file_path"] != nil ? "file_path" : "path")
        case "WebFetch":
            kind = .fetch
            detail = input["url"]?.string ?? ""
        case "WebSearch":
            kind = .search
            detail = input["query"]?.string ?? ""
        case let name where name.hasPrefix("mcp__"):
            let parts = name.split(separator: "_", omittingEmptySubsequences: true)
            kind = .mcp(server: parts.count > 2 ? String(parts[1]) : name)
            detail = parts.count > 2 ? parts.dropFirst(2).joined(separator: "_") : name
        default:
            kind = .other
            detail = input["description"]?.string ?? input.encoded().prefix(300).description
        }
        if detail.isEmpty { detail = tool }
    }
}
