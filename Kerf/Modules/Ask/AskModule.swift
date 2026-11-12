import AppKit
import KerfKit
import SwiftUI

/// ⌥ Space: one field for Claude and Google. Claude runs through Claude Code with your
/// subscription (Opus), Google opens in the browser.
@Observable
final class AskModule {
    static let shared = AskModule()

    struct Attachment: Identifiable, Equatable {
        enum Kind: Equatable {
            case file, screenshot
            case selection(String)
        }

        let id = UUID()
        var url: URL?
        var kind: Kind

        var title: String {
            switch kind {
            case .file, .screenshot: url?.lastPathComponent ?? ""
            case .selection(let text): String(text.prefix(40))
            }
        }
    }

    var text = ""
    /// Tab overrides the guess.
    var routeOverride: AskRoute?
    private(set) var attachments: [Attachment] = []
    private(set) var answer = ""
    private(set) var question = ""
    private(set) var isRunning = false
    private(set) var usingTool: String?
    private(set) var failure: String?
    private(set) var history: [Conversation] = []
    @ObservationIgnored private var current: Conversation?
    @ObservationIgnored private var process: Process?

    var route: AskRoute { routeOverride ?? AskRoute.guess(text, hasAttachments: !attachments.isEmpty) }

    var hasAnswer: Bool { !answer.isEmpty || isRunning || failure != nil }

    nonisolated private static var historyURL: URL { KerfPaths.support.appendingPathComponent("conversations.json") }
    nonisolated static var workFolder: URL { KerfPaths.support.appendingPathComponent("Ask", isDirectory: true) }

    func start() {
        Task.detached(priority: .utility) {
            let loaded = (try? Data(contentsOf: Self.historyURL)).flatMap { try? JSONDecoder().decode([Conversation].self, from: $0) } ?? []
            await MainActor.run { AskModule.shared.history = loaded }
        }
    }

    func toggleRoute() {
        routeOverride = route == .claude ? .google : .claude
    }

    func attach(_ urls: [URL]) {
        attachments += urls.map { Attachment(url: $0, kind: .file) }
        routeOverride = nil
    }

    func attachSelection(_ text: String) {
        attachments.removeAll { if case .selection = $0.kind { true } else { false } }
        attachments.append(Attachment(url: nil, kind: .selection(text)))
    }

    func remove(_ attachment: Attachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    /// Starts over: no answer, no attachments, a fresh Claude session.
    func newConversation() {
        cancel()
        current = nil
        answer = ""
        question = ""
        failure = nil
        attachments = []
        text = ""
        routeOverride = nil
    }

    func show(_ conversation: Conversation) {
        cancel()
        current = conversation
        question = conversation.question
        answer = conversation.answer
        failure = nil
    }

    func submit() {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty || !attachments.isEmpty else { return }
        if route == .google {
            if let url = AskRoute.googleURL(typed) { NSWorkspace.shared.open(url) }
            text = ""
            IslandManager.current?.closeAll()
            return
        }
        ask(typed)
    }

    // MARK: Claude

    nonisolated static func claudeExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude", "\(home)/.local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func ask(_ typed: String) {
        guard let executable = Self.claudeExecutable() else {
            failure = String(localized: "Claude Code isn't installed. Kerf uses it to ask Claude with your subscription.")
            return
        }
        cancel()
        var prompt = typed
        var folders = Set<String>()
        for attachment in attachments {
            switch attachment.kind {
            case .file, .screenshot:
                if let url = attachment.url {
                    prompt += "\n\nAttached: \(url.path)"
                    folders.insert(url.deletingLastPathComponent().path)
                }
            case .selection(let selected):
                prompt += "\n\nSelected text:\n\"\"\"\n\(selected)\n\"\"\""
            }
        }
        question = typed.isEmpty ? attachments.map(\.title).joined(separator: ", ") : typed
        answer = ""
        failure = nil
        usingTool = nil
        isRunning = true
        text = ""
        let attachmentNames = attachments.map(\.title)
        attachments = []
        routeOverride = nil

        try? FileManager.default.createDirectory(at: Self.workFolder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = Self.workFolder
        var arguments = [
            "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--model", "opus",
            "--tools", "Read,WebSearch,WebFetch", "--allowedTools", "Read,WebSearch,WebFetch",
            // Kerf's own questions shouldn't set off Kerf's hooks, or load MCP servers.
            "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config",
            "--append-system-prompt",
            "You answer inside Kerf, a small panel in the Mac's notch. Answer short and plain, in the language of the question. Use Markdown sparingly: short lists and bold, no headings, no tables.",
        ]
        if let session = current?.session { arguments += ["--resume", session] }
        if !folders.isEmpty { arguments += ["--add-dir"] + Array(folders) }
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // The prompt goes in on stdin: --add-dir would take a trailing argument as a folder.
        let input = Pipe()
        process.standardInput = input
        do {
            try process.run()
            input.fileHandleForWriting.write(Data(prompt.utf8))
            try? input.fileHandleForWriting.close()
        } catch {
            isRunning = false
            failure = error.localizedDescription
            return
        }
        self.process = process
        let conversationID = current?.id ?? UUID()
        current = Conversation(id: conversationID, question: question, answer: "", session: current?.session, attachments: attachmentNames)
        let handle = output.fileHandleForReading
        Task.detached(priority: .userInitiated) {
            for try await line in handle.bytes.lines {
                let event = ClaudeStreamEvent.parse(Data(line.utf8))
                guard event != .other else { continue }
                await MainActor.run { AskModule.shared.receive(event, for: conversationID) }
            }
            await MainActor.run { AskModule.shared.ended(conversationID) }
        }
    }

    private func receive(_ event: ClaudeStreamEvent, for id: UUID) {
        guard current?.id == id else { return }
        switch event {
        case .started(let session):
            current?.session = session
        case .text(let delta):
            usingTool = nil
            answer += delta
        case .tool(let name):
            usingTool = name
        case .finished(let final, let session, let isError):
            if isError { failure = final.isEmpty ? String(localized: "Claude couldn't answer.") : final }
            else if !final.isEmpty { answer = final }
            current?.session = session ?? current?.session
            current?.answer = answer
            isRunning = false
            usingTool = nil
            save()
        case .other:
            break
        }
        IslandManager.current?.refit()
    }

    private func ended(_ id: UUID) {
        guard current?.id == id, isRunning else { return }
        isRunning = false
        if answer.isEmpty, failure == nil { failure = String(localized: "Claude couldn't answer.") }
    }

    func cancel() {
        process?.terminate()
        process = nil
        isRunning = false
    }

    private func save() {
        guard let current, !current.answer.isEmpty else { return }
        history = Conversation.keeping(current, in: history)
        let snapshot = history
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: KerfPaths.support, withIntermediateDirectories: true)
            try? JSONEncoder().encode(snapshot).write(to: Self.historyURL, options: .atomic)
        }
    }

    func copyAnswer() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
    }

    /// Lab only.
    func preview(question: String, answer: String, running: Bool = false) {
        self.question = question
        self.answer = answer
        isRunning = running
    }
}
