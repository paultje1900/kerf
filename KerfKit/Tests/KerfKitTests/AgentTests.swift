import Foundation
import Testing
@testable import KerfKit

struct AgentEventTests {
    let permission = JSONValue.parse(Data(#"""
    {"session_id":"abc","cwd":"/Users/me/GitHub/atlas","hook_event_name":"PermissionRequest","tool_name":"Bash",
     "tool_input":{"command":"rm -rf node_modules","description":"Remove"},
     "permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf node_modules"}],"behavior":"allow","destination":"session"}]}
    """#.utf8))!

    @Test func readsAPermissionRequest() {
        guard case .permission(let tool, let input, let suggestions) = AgentEvent(permission) else {
            Issue.record("not a permission")
            return
        }
        #expect(tool == "Bash")
        #expect(input["command"]?.string == "rm -rf node_modules")
        #expect(suggestions.count == 1)
        #expect(permission.project == "atlas")
        #expect(AgentEnvelope(agent: .claudeCode, payload: permission).waitsForReply)
    }

    @Test func allowDenyAndAlways() throws {
        let event = AgentEvent(permission)
        let allow = try #require(HookOutput.json(for: event, reply: .init(decision: .allow), agent: .claudeCode))
        #expect(String(decoding: allow, as: UTF8.self) == #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
        let deny = try #require(HookOutput.json(for: event, reply: .init(decision: .deny), agent: .codex))
        #expect(JSONValue.parse(deny)?["hookSpecificOutput"]?["decision"]?["behavior"]?.string == "deny")
        #expect(JSONValue.parse(deny)?["hookSpecificOutput"]?["decision"]?["message"]?.string != nil)
        let always = try #require(HookOutput.json(for: event, reply: .init(decision: .always), agent: .claudeCode))
        let rule = JSONValue.parse(always)?["hookSpecificOutput"]?["decision"]?["updatedPermissions"]?.array?.first
        #expect(rule?["destination"]?.string == "localSettings")
        #expect(rule?["rules"]?.array?.first?["ruleContent"]?.string == "rm -rf node_modules")
        #expect(HookOutput.json(for: event, reply: .init(decision: .passThrough), agent: .claudeCode) == nil)
    }

    @Test func answersAQuestion() throws {
        let payload = JSONValue.parse(Data(#"""
        {"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which framework?","header":"Framework","options":[{"label":"React","description":"Components"},{"label":"Vue"}],"multiSelect":false}]}}
        """#.utf8))!
        let event = AgentEvent(payload)
        guard case .question(let questions, _) = event else {
            Issue.record("not a question")
            return
        }
        #expect(questions.first?.options.map(\.label) == ["React", "Vue"])
        let output = try #require(HookOutput.json(for: event, reply: .init(decision: .allow, answers: ["Which framework?": "Vue"]), agent: .claudeCode))
        let json = JSONValue.parse(output)?["hookSpecificOutput"]
        #expect(json?["permissionDecision"]?.string == "allow")
        #expect(json?["updatedInput"]?["answers"]?["Which framework?"]?.string == "Vue")
        #expect(json?["updatedInput"]?["questions"]?.array?.count == 1)
    }

    @Test func summarisesTools() {
        #expect(ToolSummary(tool: "Bash", input: ["command": "ls"]).detail == "ls")
        let edit = ToolSummary(tool: "Edit", input: ["file_path": "/p/atlas/Atlas/App.swift"], cwd: "/p/atlas")
        #expect(edit.kind == .edit)
        #expect(edit.detail == "Atlas/App.swift")
        #expect(ToolSummary(tool: "mcp__github__create_issue", input: .object([:])).kind == .mcp(server: "github"))
        #expect(ToolSummary(tool: "shell", input: ["command": .array(["git", "status"])]).detail == "git status")
    }
}

struct HookInstallerTests {
    let existing = """
    {
      "model": "opus",
      "hooks": {
        "Stop": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "say done"
              }
            ]
          }
        ]
      },
      "statusLine": {
        "type": "command",
        "command": "echo hi",
        "padding": 0
      }
    }

    """

    @Test func keepsTheFileAndAddsHooks() throws {
        let installed = try HookInstaller.install(into: existing, agent: .claudeCode)
        #expect(HookInstaller.isInstalled(in: installed, agent: .claudeCode))
        #expect(installed.contains(#""command": "say done""#))
        #expect(installed.contains(#""padding": 0"#))
        #expect(installed.hasPrefix("{\n  \"model\": \"opus\",\n  \"hooks\""))
        #expect(installed.contains(#""matcher": "AskUserQuestion""#))
        // Installing twice changes nothing.
        #expect(try HookInstaller.install(into: installed, agent: .claudeCode) == installed)
        // Removing gives the original back.
        #expect(try HookInstaller.remove(from: installed, agent: .claudeCode) == existing)
    }

    @Test func knowsWhenHooksAreOutdated() throws {
        let current = try HookInstaller.install(into: nil, agent: .claudeCode)
        #expect(HookInstaller.isCurrent(in: current, agent: .claudeCode))
        // An older Kerf installed no PostToolUse hooks.
        var root = try OrderedJSON.parse(current)
        var events = try #require(root["hooks"])
        events["PostToolUse"] = nil
        events["PostToolUseFailure"] = nil
        root["hooks"] = events
        let older = root.printed()
        #expect(HookInstaller.isInstalled(in: older, agent: .claudeCode))
        #expect(!HookInstaller.isCurrent(in: older, agent: .claudeCode))
        #expect(!HookInstaller.isCurrent(in: nil, agent: .claudeCode))
    }

    @Test func vsCodeQuestionsOnlyWait() {
        let payload: JSONValue = .object(["hook_event_name": "PreToolUse", "tool_name": "vscode_askQuestions", "tool_input": .object([
            "questions": .array([.object(["header": "Stap 1", "question": "Mag stap 1 door?", "options": .array([.object(["label": "Ja"])])])]),
        ])])
        #expect(AgentEvent(payload) == .askedInApp(tool: "vscode_askQuestions"))
        #expect(!AgentEnvelope(agent: .copilot, payload: payload).waitsForReply)
    }

    @Test func toolsFinishing() {
        #expect(AgentEvent(.object(["hook_event_name": "PostToolUse", "tool_name": "Bash"])) == .toolFinished(tool: "Bash"))
        #expect(AgentEvent(.object(["hook_event_name": "PostToolUseFailure", "tool_name": "Edit"])) == .toolFinished(tool: "Edit"))
    }

    @Test func startsANewFile() throws {
        let file = try HookInstaller.install(into: nil, agent: .codex)
        #expect(HookInstaller.isInstalled(in: file, agent: .codex))
        #expect(!HookInstaller.isInstalled(in: file, agent: .claudeCode))
        #expect(try HookInstaller.remove(from: file, agent: .codex) == "{}\n")
    }

    @Test func keepsEscapesAndNumbers() throws {
        let text = #"{"a": "tab\tquote\" é é 😀", "n": 1.50e3, "list": []}"#
        let printed = try OrderedJSON.parse(text).printed()
        #expect(printed.contains(#""tab\tquote\" é é 😀""#))
        #expect(printed.contains("1.50e3"))
        #expect(printed.contains(#""list": []"#))
    }

    @Test func diffShowsOnlyChanges() {
        let lines = LineDiff.lines(from: "a\nb\nc\nd\ne\nf\ng", to: "a\nb\nc\nX\ne\nf\ng", context: 1)
        #expect(lines == ["  c", "+ X", "- d", "  e"] || lines == ["  c", "- d", "+ X", "  e"])
    }
}

struct UnixSocketTests {
    @Test func roundTripAndHangUp() async throws {
        let path = NSTemporaryDirectory() + "kerf-test-\(UInt32.random(in: 0...99999)).sock"
        let closed = Flag()
        let server = try UnixSocketServer(path: path) { line, connection in
            if line == Data("ping".utf8) { connection.reply(Data("pong".utf8)) }
            else { connection.onClose = { closed.set() } }
        }
        defer { server.stop() }
        #expect(UnixSocket.send(Data("ping".utf8), to: path, waitForReply: true, timeout: 2) == Data("pong".utf8))
        // Nobody answers "wait": the client gives up, the server notices.
        #expect(UnixSocket.send(Data("wait".utf8), to: path, waitForReply: true, timeout: 0.3) == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(closed.value)
        #expect(UnixSocket.send(Data("x".utf8), to: path + ".missing", waitForReply: false, timeout: 1) == nil)
    }

    @Test func anOldServerLeavesTheNewSocket() throws {
        let path = NSTemporaryDirectory() + "kerf-test-\(UInt32.random(in: 0...99999)).sock"
        let old = try UnixSocketServer(path: path) { _, connection in connection.reply(Data("old".utf8)) }
        let new = try UnixSocketServer(path: path) { _, connection in connection.reply(Data("new".utf8)) }
        defer { new.stop() }
        old.stop()
        #expect(UnixSocket.send(Data("hi".utf8), to: path, waitForReply: true, timeout: 2) == Data("new".utf8))
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var value: Bool { lock.withLock { on } }
    func set() { lock.withLock { on = true } }
}

extension JSONValue: ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }

    public init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }
}

struct AgentDetailsTests {
    @Test func outermostApp() {
        let helper = "/Applications/T3 Code (Nightly).app/Contents/Frameworks/T3 Code (Nightly) Helper.app/Contents/MacOS/T3 Code (Nightly) Helper"
        #expect(ProcessTree.app(containing: helper) == ProcessTree.App(name: "T3 Code (Nightly)", bundlePath: "/Applications/T3 Code (Nightly).app"))
        #expect(ProcessTree.app(containing: "/opt/homebrew/bin/claude") == nil)
        // The desktop app's bundled Claude Code CLI is skipped, so the walk reaches Claude.app.
        let cli = "/Users/me/Library/Application Support/Claude/claude-code/2.1.309/5af865b9901c/claude.app/Contents/MacOS/claude"
        #expect(ProcessTree.app(containing: cli) == nil)
        #expect(ProcessTree.app(containing: "/Applications/Claude.app/Contents/Helpers/disclaimer")
            == ProcessTree.App(name: "Claude", bundlePath: "/Applications/Claude.app"))
    }

    @Test func titles() {
        #expect(ThreadTitle.from(prompt: "\n  Fix the timer page\nand more") == "Fix the timer page")
        #expect(ThreadTitle.from(prompt: "<command-name>/compact</command-name>") == nil)
        let transcript = Data("""
        {"type":"summary","summary":"x"}
        {"type":"user","message":{"role":"user","content":"<command-message>init</command-message>"}}
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"Make the notch app"}]}}
        """.utf8)
        #expect(ThreadTitle.fromTranscript(transcript) == "Make the notch app")
        let codex = Data(#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Review the PR"}]}}"#.utf8)
        #expect(ThreadTitle.fromTranscript(codex) == "Review the PR")
    }

    @Test func namedTitles() {
        // Cut off mid-line, as a tail read is.
        let generated = Data("""
        ype":"user"}
        {"type":"ai-title","aiTitle":"Set up the project","sessionId":"a"}
        {"type":"user","message":{"role":"user","content":"x"},"note":"ai-title"}
        {"type":"ai-title","aiTitle":"Port the waiting dot","sessionId":"a"}
        """.utf8)
        #expect(ThreadTitle.named(inTail: generated) == "Port the waiting dot")
        // A rename wins over Claude Code's own name, wherever it is.
        let renamed = Data("""
        {"type":"custom-title","customTitle":"Waiting dot","sessionId":"a"}
        {"type":"ai-title","aiTitle":"Port the waiting dot","sessionId":"a"}
        """.utf8)
        #expect(ThreadTitle.named(inTail: renamed) == "Waiting dot")
        #expect(ThreadTitle.named(inTail: Data(#"{"type":"user","message":{"content":"Hi"}}"#.utf8)) == nil)
    }

    @Test func projectNames() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kerf-project-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent("atlas")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git/worktrees/fix"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("Atlas/Views"), withIntermediateDirectories: true)
        #expect(ProjectName.of(repo.appendingPathComponent("Atlas/Views").path) == "atlas")
        let worktree = base.appendingPathComponent("2026-10-31-fix-timer")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(repo.path)/.git/worktrees/fix\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(ProjectName.of(worktree.path) == "atlas")
        #expect(ProjectName.of("/Users/me/.t3/scratch/2026-10-31-x") == nil)
        #expect(ProjectName.of("/Users/me/.p3code/scratch/2026-11-01-x") == nil)
    }
}

struct CopilotTests {
    @Test func normalisesCamelCase() throws {
        let payload = try #require(JSONValue.parse(Data(#"""
        {"sessionId":"s1","timestamp":1704614600000,"cwd":"/Users/me/GitHub/atlas","toolName":"bash","toolArgs":"{\"command\":\"npm test\"}"}
        """#.utf8)))
        let normalized = CopilotPayload.normalized(payload, event: "PermissionRequest")
        #expect(normalized.sessionID == "s1")
        #expect(normalized["hook_event_name"]?.string == "PermissionRequest")
        guard case .permission(let tool, let input, _) = AgentEvent(normalized) else {
            Issue.record("not a permission")
            return
        }
        #expect(tool == "bash")
        #expect(input["command"]?.string == "npm test")
        #expect(ToolSummary(tool: tool, input: input).kind == .command)
        #expect(AgentEnvelope(agent: .copilot, payload: normalized).waitsForReply)
    }

    @Test func keepsSnakeCaseAndItsEventName() throws {
        let payload = try #require(JSONValue.parse(Data(#"""
        {"hook_event_name":"UserPromptSubmit","session_id":"s2","cwd":"/tmp","prompt":"Fix the tests"}
        """#.utf8)))
        let normalized = CopilotPayload.normalized(payload, event: "Stop")
        #expect(normalized == payload)
        #expect(AgentEvent(normalized) == .promptSubmitted("Fix the tests"))
    }

    @Test func answersWithBehaviorAtTheTop() throws {
        let event = AgentEvent.permission(tool: "bash", input: .object(["command": "ls"]), suggestions: [])
        let allow = try #require(HookOutput.json(for: event, reply: .init(decision: .allow), agent: .copilot))
        #expect(JSONValue.parse(allow)?["behavior"]?.string == "allow")
        #expect(JSONValue.parse(allow)?["hookSpecificOutput"]?["decision"]?["behavior"]?.string == "allow")
        let deny = try #require(HookOutput.json(for: event, reply: .init(decision: .deny), agent: .copilot))
        #expect(JSONValue.parse(deny)?["behavior"]?.string == "deny")
        #expect(JSONValue.parse(deny)?["message"]?.string != nil)
        // No rule to keep: always is allow once.
        let always = try #require(HookOutput.json(for: event, reply: .init(decision: .always), agent: .copilot))
        #expect(JSONValue.parse(always)?["updatedPermissions"] == nil)
        #expect(!AgentKind.copilot.remembersAlways)
    }

    @Test func ownHooksFile() throws {
        let text = HookInstaller.copilotFile()
        let root = try OrderedJSON.parse(text)
        #expect(root["version"] == .number("1"))
        #expect(root["hooks"]?["PermissionRequest"] == nil)
        #expect(root["hooks"]?["PreToolUse"]?.arrayValue?.first?["bash"]?.stringValue
            == #""$HOME/Library/Application Support/Kerf/bin/kerf" hook copilot PreToolUse || true"#)
        #expect(HookInstaller.hooks(for: .claudeCode).contains { $0.event == "PermissionRequest" && $0.timeout == 600 })
        #expect(root["hooks"]?["Stop"]?.arrayValue?.first?["timeoutSec"] == .number("10"))
        #expect(HookInstaller.isCopilotFile(text))
        #expect(!HookInstaller.isCopilotFile(nil))
        #expect(!HookInstaller.isCopilotFile(#"{"version":1,"hooks":{"preToolUse":[{"type":"command","bash":"./check.sh"}]}}"#))
    }
}

struct RunningThreadTests {
    private func lines(_ entries: String...) -> Data { Data(entries.joined(separator: "\n").utf8) }

    @Test func namesTheProjectFolderLikeClaudeCode() {
        #expect(ClaudeTranscript.folderName(for: "/Users/me/.p3code/scratch/2026-11-01-kerf-6944a0e5")
            == "-Users-me--p3code-scratch-2026-11-01-kerf-6944a0e5")
    }

    @Test func readsTheSessionFromTheArguments() {
        #expect(ClaudeTranscript.sessionID(in: ["--verbose", "--session-id=9c0a"]) == "9c0a")
        #expect(ClaudeTranscript.sessionID(in: ["--resume", "77ab", "--verbose"]) == "77ab")
        #expect(ClaudeTranscript.sessionID(in: ["--output-format", "stream-json"]) == nil)
    }

    @Test func knowsWhetherATurnIsStillGoing() {
        let prompt = #"{"type":"user","message":{"role":"user","content":"Fix the mixer"}}"#
        let tool = #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use"}]}}"#
        let result = #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#
        let done = #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}"#
        let interrupted = #"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        let bookkeeping = #"{"type":"system","subtype":"stop_hook_summary"}"#
        #expect(ClaudeTranscript.isMidTurn(lines(#"{"cut off"#, prompt, #"{"type":"api-request"}"#)))
        #expect(ClaudeTranscript.isMidTurn(lines(prompt, tool)))
        #expect(ClaudeTranscript.isMidTurn(lines(tool, result)))
        #expect(!ClaudeTranscript.isMidTurn(lines(prompt, done, bookkeeping, #"{"type":"last-prompt"}"#)))
        #expect(!ClaudeTranscript.isMidTurn(lines(tool, interrupted)))
        #expect(!ClaudeTranscript.isMidTurn(Data()))
    }

    @Test func findsTheClaudeProcessesThatRun() {
        // Only checks that scanning this Mac works and doesn't crash; what it finds depends on the moment.
        _ = RunningThreads.claudeCode()
        #expect(RunningThreads.workingDirectory(getpid()) != nil)
        #expect(RunningThreads.arguments(getpid()).isEmpty == false || CommandLine.arguments.count <= 1)
    }
}

struct CodeThreadLinkTests {
    @Test func findsTheChatForASession() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("kerf-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent(".p3code/userdata")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "488cda2c-env\n".write(to: folder.appendingPathComponent("environment-id"), atomically: true, encoding: .utf8)
        let database = folder.appendingPathComponent("statev2.sqlite").path
        let sql = """
            CREATE TABLE orchestration_v2_projection_provider_threads (provider_thread_id TEXT PRIMARY KEY, thread_id TEXT,
              updated_at TEXT NOT NULL, payload_json TEXT NOT NULL);
            INSERT INTO orchestration_v2_projection_provider_threads VALUES
              ('a', '0bd1bcee-thread', '2026-11-01T11:00:00Z', '{"nativeThreadRef":{"driver":"claudeAgent","nativeId":"e07d33e8-session"}}'),
              ('b', 'other-thread', '2026-11-01T12:00:00Z', '{"nativeThreadRef":{"driver":"claudeAgent","nativeId":"someone-else"}}');
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database, sql]
        try process.run()
        process.waitUntilExit()
        let link = CodeThreadLink.url(hostPath: "/Applications/P3 Code.app", sessionID: "e07d33e8-session", home: home)
        #expect(link?.absoluteString == "t3code://threads/488cda2c-env/0bd1bcee-thread")
        #expect(CodeThreadLink.url(hostPath: "/Applications/P3 Code.app", sessionID: "unknown", home: home) == nil)
        #expect(CodeThreadLink.url(hostPath: "/System/Applications/Utilities/Terminal.app", sessionID: "e07d33e8-session", home: home) == nil)
    }
}

struct StopFailureTests {
    @Test func failures() {
        #expect(AgentEvent(.object(["hook_event_name": "StopFailure", "error": "rate_limit", "error_details": "429 Too Many Requests"]))
            == .stopFailed(error: "rate_limit", details: "429 Too Many Requests"))
        #expect(AgentEvent(.object(["hook_event_name": "StopFailure"])) == .stopFailed(error: "unknown", details: nil))
    }
}

struct SubagentTests {
    @Test func subagents() {
        #expect(AgentEvent(.object(["hook_event_name": "SubagentStart", "agent_id": "a1", "agent_type": "Explore"])) == .subagentStarted(id: "a1"))
        #expect(AgentEvent(.object(["hook_event_name": "SubagentStop", "agent_id": "a1"])) == .subagentStopped(id: "a1"))
        #expect(AgentEvent(.object(["hook_event_name": "Stop", "background_tasks": .array([])])) == .stop(lastMessage: nil, subagentsRunning: false))
        #expect(AgentEvent(.object(["hook_event_name": "Stop", "background_tasks": .array([.object(["id": "t1", "type": "subagent"])])]))
            == .stop(lastMessage: nil, subagentsRunning: true))
    }
}

struct ThreadLinkTests {
    @Test func links() {
        #expect(ThreadLink.of(host: "/System/Applications/Utilities/Terminal.app", tty: "/dev/ttys003", project: "kerf", desktopSessionID: nil)
            == .terminalTab(script: ThreadLink.terminalScript("/dev/ttys003")))
        // A tty that isn't one never reaches the script.
        #expect(ThreadLink.of(host: "/Applications/iTerm.app", tty: "/dev/ttys003\" & quit", project: nil, desktopSessionID: nil) == .app)
        #expect(ThreadLink.of(host: "/Applications/Claude.app", tty: nil, project: "kerf", desktopSessionID: "local_661abf77-b1c8")
            == .url(URL(string: "claude://code/continue?session=local_661abf77-b1c8")!))
        #expect(ThreadLink.of(host: "/Applications/Claude.app", tty: nil, project: "kerf", desktopSessionID: nil) == .app)
        #expect(ThreadLink.of(host: "/Applications/Visual Studio Code.app", tty: nil, project: "kerf", desktopSessionID: nil) == .window(project: "kerf"))
        // With its folder, VS Code opens that and needs no Accessibility; a subfolder goes up to the repository.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().path
        #expect(ThreadLink.of(host: "/Applications/Visual Studio Code.app", tty: nil, project: "kerf", cwd: repo + "/KerfKit/Sources",
                              desktopSessionID: nil) == .folder(repo))
        #expect(ThreadLink.of(host: "/Applications/Xcode.app", tty: nil, project: "kerf", cwd: repo, desktopSessionID: nil) == .window(project: "kerf"))
        #expect(ThreadLink.title("AgentCenter.swift — kerf — Visual Studio Code", names: "kerf"))
        #expect(!ThreadLink.title("README.md — kerf-upstream — Visual Studio Code", names: "kerf"))
        #expect(ThreadLink.title("kerf", names: "kerf"))
    }

    @Test func desktopSessions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let org = folder.appendingPathComponent("account/org")
        try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
        try Data(#"{"sessionId":"local_661abf77","cliSessionId":"b095e46e"}"#.utf8).write(to: org.appendingPathComponent("local_661abf77.json"))
        #expect(ThreadLink.desktopSessionID(forCLI: "b095e46e", in: folder) == "local_661abf77")
        #expect(ThreadLink.desktopSessionID(forCLI: "other", in: folder) == nil)
        try? FileManager.default.removeItem(at: folder)
    }
}
