import AppKit
import ApplicationServices
import KerfKit
import OSLog
import SwiftUI

/// Claude Code, Codex, T3 Code and anything using `kerf notify`: their sessions, and the
/// questions waiting for you. Only those questions leave a dot in the notch.
@Observable
final class AgentCenter {
    static let shared = AgentCenter()

    struct Session: Identifiable, Equatable {
        enum State {
            case working, waiting, idle
        }

        let id: String
        var agent: AgentKind
        var name: String
        var hostPath: String?
        var project: String?
        var state: State {
            didSet { if state != oldValue { stateSince = .now } }
        }
        var updated: Date
        var lastMessage: String?
        /// The first thing you asked in this thread.
        var title: String?
        /// Finished since you last looked.
        var unread = false
        /// Asks for you in its own window; unread too.
        var needsInput = false
        /// Found running without a hook having said so; the next hook event takes over.
        var foundByScan = false
        /// The agent's own session id, for finding its chat in P3 or T3 Code.
        var nativeID: String?
        /// The turn ended on an API error (`rate_limit`, `overloaded`, …) instead of finishing.
        var failure: String?
        /// Subagents running for this thread, by their id.
        var subagents: Set<String> = []
        /// Since when it works, waits or is done.
        var stateSince = Date.now
        var repository: RepositoryContext?
        /// The terminal it runs in, to pick the right tab: `/dev/ttys003`.
        var tty: String?
        /// Where it works, to open that folder in its editor.
        var cwd: String?
    }

    struct Request: Identifiable {
        let id = UUID()
        let sessionID: String
        let agent: AgentKind
        let name: String
        let hostPath: String?
        let project: String?
        let cwd: String?
        let event: AgentEvent
        let connection: UnixSocketServer.Connection?
    }

    private(set) var sessions: [Session] = []
    private(set) var requests: [Request] = [] {
        didSet {
            navigation.update(requests.map(\.id))
            questionDrafts = questionDrafts.filter { navigation.ids.contains($0.key) }
        }
    }
    /// Whether any agent's hooks point at Kerf: read at launch, when the page opens and after
    /// Settings changes them, never while drawing.
    private(set) var hasConnectedAgent = true
    var navigation = RequestNavigation()
    var questionDrafts: [UUID: QuestionDraft] = [:]
    @ObservationIgnored private var contextTask: Task<Void, Never>?
    @ObservationIgnored private var isPreview = false
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Kerf", category: "Agents")
    @ObservationIgnored private var server: UnixSocketServer?
    @ObservationIgnored private var frontObserver: NSObjectProtocol?
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    static let showsDoneKey = "agents.showsDone"
    static let soundsDoneKey = "agents.soundsDone"
    /// On by default: while you're in a thread's own app, it asks there and Kerf only shows the dot.
    static let asksInFrontAppKey = "agents.asksInFrontApp"
    static var asksInFrontApp: Bool { UserDefaults.standard.object(forKey: asksInFrontAppKey) as? Bool ?? true }

    func checkConnections() {
        guard !isPreview else { return }
        let connected = HookTarget.allCases.contains(where: \.isInstalled)
        if connected != hasConnectedAgent { hasConnectedAgent = connected }
    }

    func start() {
        guard server == nil else { return }
        checkConnections()
        let files = FileManager.default
        try? files.createDirectory(at: KerfPaths.commandLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Hooks call a stable path; point it at this copy of the app.
        if let executable = Bundle.main.executablePath {
            try? files.removeItem(at: KerfPaths.commandLink)
            try? files.createSymbolicLink(atPath: KerfPaths.commandLink.path, withDestinationPath: executable)
        }
        server = try? UnixSocketServer(path: KerfPaths.socket) { line, connection in
            Task { @MainActor in AgentCenter.shared.receive(line, connection) }
        }
        // Going to a thread's app takes its questions along: they show there instead.
        frontObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                                          queue: .main) { note in
            let path = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL?.path
            Task { @MainActor in AgentCenter.shared.cameForward(path) }
        }
        findRunning()
        scanTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                AgentCenter.shared.findRunning()
            }
        }
    }

    /// Threads already busy before Kerf heard of them: started before Kerf, or while it restarted.
    /// At launch and when the AI page opens; hooks tell the rest.
    /// Also once a minute, to let go of threads whose window was closed without a SessionEnd.
    func findRunning() {
        guard !isPreview, Feature.agents.isOn else { return }
        Task.detached(priority: .utility) {
            let found = RunningThreads.claudeCode()
            let terminals = RunningThreads.liveTerminals()
            await MainActor.run { AgentCenter.shared.merge(found, terminals: terminals) }
        }
        refreshRepositories()
    }

    func refreshRepositories() {
        guard !isPreview, contextTask == nil else { return }
        let directories = Set(sessions.compactMap(\.cwd))
        contextTask = Task {
            let results = await Task.detached(priority: .utility) {
                directories.map { directory in
                    (directory, Result { try RepositoryContext.read(at: directory) })
                }
            }.value
            for (directory, result) in results {
                switch result {
                case .success(let context):
                    for index in sessions.indices where sessions[index].cwd == directory {
                        sessions[index].repository = context
                    }
                case .failure(let error):
                    for index in sessions.indices where sessions[index].cwd == directory {
                        sessions[index].repository = nil
                    }
                    logger.error("Repository context: \(error.localizedDescription, privacy: .public)")
                }
            }
            contextTask = nil
            GitHubModule.shared.prioritize()
            Hub.shared.refresh()
        }
    }

    var selectedRequest: Request? {
        guard !navigation.showsOverview else { return nil }
        return requests.first { $0.id == navigation.selectedID }
    }

    func request(for session: Session) -> Request? {
        requests.first { $0.sessionID == session.id }
    }

    func projectLabel(for session: Session) -> String? {
        guard let project = session.project else { return nil }
        guard let context = session.repository,
              RepositoryContext.needsBranch(context, among: visibleThreads.compactMap(\.repository)) else { return project }
        return "\(project) · \(context.label)"
    }

    func projectLabel(for request: Request) -> String? {
        sessions.first { $0.id == request.sessionID }.flatMap { projectLabel(for: $0) } ?? request.project
    }

    private func merge(_ found: [RunningThreads.Found], terminals: Set<String>) {
        // A look that started just before the agents were switched off.
        guard Feature.agents.isOn else { return }
        var next = sessions
        // Its terminal tab or its app is gone: so is the thread, whatever it last said.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
        next.removeAll { session in
            if let tty = session.tty { return !terminals.contains(tty) }
            if let host = session.hostPath { return !running.contains(host) }
            return false
        }
        let ids = Set(found.map { "\(AgentKind.claudeCode.rawValue)..\($0.sessionID)" })
        // A guess whose turn ended without a hook (Kerf missed it) goes again.
        next.removeAll { $0.foundByScan && !ids.contains($0.id) }
        for thread in found {
            let id = "\(AgentKind.claudeCode.rawValue)..\(thread.sessionID)"
            guard !next.contains(where: { $0.id == id }) else { continue }
            var session = Session(id: id, agent: .claudeCode, name: AgentKind.claudeCode.displayName, hostPath: thread.hostPath,
                                  project: ProjectName.of(thread.cwd), state: .working, updated: thread.updated, title: thread.title)
            session.foundByScan = true
            session.nativeID = thread.sessionID
            session.stateSince = thread.updated
            session.tty = thread.tty
            session.cwd = thread.cwd
            next.append(session)
        }
        next.sort { $0.updated > $1.updated }
        guard next != sessions else { return }
        sessions = next
        refreshRepositories()
        Hub.shared.refresh()
    }

    /// Lab only: a fresh install, no agent connected yet.
    func previewUnconnected() {
        isPreview = true
        hasConnectedAgent = false
        sessions = []
    }

    func stop() {
        server?.stop()
        server = nil
    }

    /// Switched off: what waits goes back to its tool, which asks as it always does.
    func switchOff() {
        stop()
        scanTask?.cancel()
        scanTask = nil
        if let frontObserver { NSWorkspace.shared.notificationCenter.removeObserver(frontObserver) }
        frontObserver = nil
        for request in requests { answer(request, AgentReply(decision: .passThrough)) }
        sessions = []
        Hub.shared.refresh()
    }

    private func receive(_ line: Data, _ connection: UnixSocketServer.Connection) {
        guard let envelope = try? JSONDecoder().decode(AgentEnvelope.self, from: line) else {
            connection.reply(nil)
            return
        }
        handle(envelope, connection: connection)
    }

    func handle(_ envelope: AgentEnvelope, connection: UnixSocketServer.Connection?) {
        let payload = envelope.payload
        if payload["hook_event_name"]?.string == "KerfDebug" {
            let music = NowPlayingModule.shared
            let report: JSONValue = .object([
                "nowPlaying": music.state.map { .string("\($0.title) [\($0.isPlaying ? "playing" : "paused")] \($0.sourceBundleID)") } ?? .null,
                "musicUpdated": music.lastUpdate.map { .string($0.formatted(.iso8601)) } ?? .null,
                "compact": .string(Hub.shared.presentation.map { $0.kind } ?? "none"),
                "pages": .string(Hub.shared.pages.map(\.rawValue).joined(separator: ",")),
                "more": .string(Hub.shared.morePages.map(\.rawValue).joined(separator: ",")),
                "threads": .number(Double(visibleThreads.count)),
                "accessibility": .bool(AXIsProcessTrusted()),
                "mediaKeys": .bool(MediaKeys.shared.isRunning),
                "mixer": .string(AppMixer.shared.channels.map { "\($0.name) \(Int($0.gain * 100))%\($0.isPlaying ? " playing" : "")" }.joined(separator: ", ")),
                "islands": .array(IslandManager.current?.displayVisibility ?? []),
                "waiting": .number(Double(requests.count)),
                "list": .array(visibleThreads.map { session in
                    .object([
                        "id": .string(session.id),
                        "title": session.title.map(JSONValue.string) ?? .null,
                        "state": .string("\(session.state)"),
                        "host": session.hostPath.map(JSONValue.string) ?? .null,
                        "tty": session.tty.map(JSONValue.string) ?? .null,
                    ])
                }),
                "blocked": .number(Double(waitingSessions.count)),
            ])
            connection?.reply(report.encoded())
            return
        }
        // `kerf open`: a thread as if clicked, by (part of) its id.
        if payload["hook_event_name"]?.string == "KerfOpen" {
            connection?.reply(nil)
            if let id = payload["thread"]?.string, let session = sessions.first(where: { $0.id.contains(id) }) { open(session) }
            return
        }
        // `kerf answer`: answer the first waiting question from a script.
        if payload["hook_event_name"]?.string == "KerfAnswer" {
            connection?.reply(nil)
            if let request = requests.first, let decision = payload["decision"]?.string.flatMap(AgentReply.Decision.init) {
                answer(request, AgentReply(decision: decision))
            }
            return
        }
        let event = AgentEvent(payload)
        let name = envelope.name ?? envelope.agent.displayName
        let sessionID = "\(envelope.agent.rawValue).\(envelope.name ?? "").\(payload.sessionID)"
        let isNew = !sessions.contains { $0.id == sessionID }
        var session = sessions.first { $0.id == sessionID }
            ?? Session(id: sessionID, agent: envelope.agent, name: name, hostPath: envelope.host, project: payload.project, state: .idle, updated: .now)
        session.updated = .now
        session.foundByScan = false
        if !payload.sessionID.isEmpty { session.nativeID = payload.sessionID }
        session.project = payload.project ?? session.project
        session.hostPath = envelope.host ?? session.hostPath
        session.tty = envelope.tty ?? session.tty
        session.cwd = payload.workingDirectory ?? session.cwd
        // A thread Kerf joins halfway gets its title from the transcript.
        if isNew, session.title == nil, let transcript = payload.transcriptPath { loadTitle(sessionID, from: transcript) }

        switch event {
        case .permission, .question:
            session.state = .waiting
            session.needsInput = false
            // You're in its app: it asks there, and the dot says it waits.
            if envelope.agent != .other, Self.asksInFrontApp,
               let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.path, Self.samePath(front, session.hostPath) {
                connection?.reply(try? JSONEncoder().encode(AgentReply(decision: .passThrough)))
                break
            }
            let request = Request(sessionID: sessionID, agent: envelope.agent, name: name, hostPath: session.hostPath,
                                  project: session.project, cwd: payload.workingDirectory, event: event, connection: connection)
            requests.append(request)
            connection?.onClose = { [id = request.id] in
                Task { @MainActor in AgentCenter.shared.drop(id) }
            }
            Sounds.play(.question)
        case .notification(let type, _):
            connection?.reply(nil)
            if envelope.agent == .other {
                Hub.shared.flash(.banner(.agent(envelope.agent), .symbol("bell.fill", Color(nsColor: .systemOrange))))
            } else if type == "permission_prompt" {
                // Claude Code shows its own prompt: the thread waits on you, also if Kerf missed the request.
                session.state = .waiting
            } else if type == "elicitation_dialog" || type == "agent_needs_input" {
                // Stays in the notch until you look or the thread moves on.
                session.needsInput = true
                session.unread = true
            }
        case .askedInApp:
            connection?.reply(nil)
            // VS Code shows the question itself; the dot stays until it moves on.
            session.state = .waiting
            session.needsInput = false
            Sounds.play(.question)
        case .toolFinished:
            connection?.reply(nil)
            // Answered somewhere, maybe in the terminal: the thread works again, unless Kerf still holds
            // one of its questions.
            if session.state == .waiting, !requests.contains(where: { $0.sessionID == sessionID }) {
                session.state = .working
            }
        case .stop(let last, let subagentsRunning):
            connection?.reply(nil)
            session.state = .idle
            session.unread = true
            session.needsInput = false
            session.failure = nil
            session.lastMessage = last.map { String($0.prefix(300)) }
            // Only background subagents outlive the turn.
            if !subagentsRunning { session.subagents = [] }
            if Self.showsDone, UserDefaults.standard.object(forKey: Self.soundsDoneKey) as? Bool ?? true { Sounds.play(.done) }
        case .stopFailed(let error, _):
            connection?.reply(nil)
            // Not done: it stopped on an error and waits for you to pick it up. Stays in the notch.
            session.state = .idle
            session.unread = true
            session.needsInput = true
            session.failure = error
        case .subagentStarted(let id):
            connection?.reply(nil)
            if !id.isEmpty { session.subagents.insert(id) }
        case .subagentStopped(let id):
            connection?.reply(nil)
            session.subagents.remove(id)
        case .sessionEnd:
            connection?.reply(nil)
            requests.removeAll { $0.sessionID == sessionID }
            sessions.removeAll { $0.id == sessionID }
            GitHubModule.shared.prioritize()
            Hub.shared.refresh()
            return
        case .promptSubmitted(let prompt):
            connection?.reply(nil)
            session.state = .working
            session.unread = false
            session.needsInput = false
            session.failure = nil
            if session.title == nil { session.title = prompt.flatMap(ThreadTitle.from) }
        case .sessionStart, .other:
            connection?.reply(nil)
        }
        if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        // Newest first, nothing older than a day.
        sessions = sessions.filter { $0.updated > .now.addingTimeInterval(-86_400) }.sorted { $0.updated > $1.updated }
        switch event {
        case .sessionStart, .promptSubmitted: refreshRepositories()
        default: if isNew { refreshRepositories() }
        }
        GitHubModule.shared.prioritize()
        Hub.shared.refresh()
    }

    func answer(_ request: Request, _ reply: AgentReply) {
        guard requests.contains(where: { $0.id == request.id }) else {
            logger.debug("Ignoring an answer to a request that is no longer pending.")
            return
        }
        if let data = try? JSONEncoder().encode(reply) {
            request.connection?.onClose = nil
            request.connection?.reply(data)
        }
        requests.removeAll { $0.id == request.id }
        if let index = sessions.firstIndex(where: { $0.id == request.sessionID }) {
            switch reply.decision {
            case _ where requests.contains(where: { $0.sessionID == request.sessionID }):
                sessions[index].state = .waiting
            // A `kerf notify --ask` has no turn that goes on: answered is done.
            case _ where request.agent == .other: sessions[index].state = .idle
            // Handed back to the tool's own window: it still waits on you there.
            case .passThrough: sessions[index].state = .waiting
            case .deny: sessions[index].state = .idle
            default: sessions[index].state = .working
            }
        }
        Hub.shared.refresh()
        if requests.isEmpty, !navigation.showsOverview { IslandManager.current?.closeAgents() }
    }

    /// Threads blocked on you: a permission or a question, in the notch or in their own window.
    /// The notch's orange dot stays while there is one, whether or not Kerf holds the question.
    var waitingSessions: [Session] {
        sessions.filter { $0.state == .waiting }
    }

    /// What the AI page lists: threads that run, wait, or finished since you last looked.
    var visibleThreads: [Session] {
        sessions.filter { $0.state != .idle || $0.unread }.sorted {
            @MainActor func priority(_ session: Session) -> Int {
                if session.state == .waiting { return 0 }
                if session.failure != nil || session.needsInput { return 1 }
                return session.state == .working ? 2 : 3
            }
            let left = priority($0), right = priority($1)
            return left == right ? $0.updated > $1.updated : left < right
        }
    }

    static var showsDone: Bool { UserDefaults.standard.object(forKey: showsDoneKey) as? Bool ?? true }

    /// What stays in the notch until you click it or the thread moves on: threads that finished
    /// or ask for him in their own window. Newest first.
    var notices: [Session] {
        let showsDone = Self.showsDone
        return sessions.filter { $0.unread && ($0.needsInput || showsDone) }
    }

    /// Seen: the thread leaves the list, and its notice leaves the notch.
    func markRead(_ id: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].unread else { return }
        sessions[index].unread = false
        sessions[index].needsInput = false
        GitHubModule.shared.prioritize()
        Hub.shared.refresh()
    }

    /// The app at `path` came to the front: what its threads ask in Kerf goes back to it.
    private func cameForward(_ path: String?) {
        guard Self.asksInFrontApp, let path else { return }
        for request in requests where request.agent != .other && Self.samePath(path, request.hostPath) {
            answer(request, AgentReply(decision: .passThrough))
        }
    }

    private static func samePath(_ path: String, _ other: String?) -> Bool {
        guard let other else { return false }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == URL(fileURLWithPath: other).resolvingSymlinksInPath().path
    }

    /// The thread's own place: in P3 or T3 Code the chat itself, else its terminal tab, its Claude
    /// desktop session or its editor window, else just the app it runs in.
    func open(_ session: Session) {
        markRead(session.id)
        guard let host = session.hostPath else { return }
        let native = session.nativeID
        Task.detached(priority: .userInitiated) {
            if let link = native.flatMap({ CodeThreadLink.url(hostPath: host, sessionID: $0) }) {
                await MainActor.run {
                    // Straight to that app: T3 Code would take the link otherwise, it has the same scheme.
                    NSWorkspace.shared.open([link], withApplicationAt: URL(fileURLWithPath: host), configuration: NSWorkspace.OpenConfiguration())
                }
                return
            }
            let desktopID = native.flatMap { ThreadLink.desktopSessionID(forCLI: $0, in: KerfPaths.claudeDesktopSessions) }
            let link = ThreadLink.of(host: host, tty: session.tty, project: session.project, cwd: session.cwd, desktopSessionID: desktopID)
            await MainActor.run { Self.follow(link, host: host) }
        }
    }

    private static func follow(_ link: ThreadLink, host: String) {
        let app = URL(fileURLWithPath: host)
        switch link {
        case .terminalTab(let script):
            // osascript, not NSAppleScript: Terminal may take a moment and the island shouldn't wait.
            // The script picks the tab and window; macOS only lets Kerf itself bring Terminal forward.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.terminationHandler = { _ in
                Task { @MainActor in openApp(app) }
            }
            if (try? process.run()) == nil { openApp(app) }
        case .url(let url):
            NSWorkspace.shared.open(url)
        case .folder(let path):
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        case .window(let project):
            openApp(app)
            WindowRaiser.raise(appAt: host) { ThreadLink.title($0, names: project) }
        case .app:
            openApp(app)
        }
    }

    private static func openApp(_ app: URL) {
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private func loadTitle(_ sessionID: String, from path: String) {
        Task.detached(priority: .utility) {
            guard let handle = FileHandle(forReadingAtPath: path) else { return }
            let head = handle.readData(ofLength: 256 * 1024)
            try? handle.close()
            guard let title = ThreadTitle.fromTranscript(head) else { return }
            await MainActor.run {
                guard let index = AgentCenter.shared.sessions.firstIndex(where: { $0.id == sessionID }),
                      AgentCenter.shared.sessions[index].title == nil else { return }
                AgentCenter.shared.sessions[index].title = title
            }
        }
    }

    /// The tool stopped waiting: answered in its own window, or timed out.
    private func drop(_ id: UUID) {
        guard let request = requests.first(where: { $0.id == id }) else { return }
        requests.removeAll { $0.id == id }
        // A `kerf notify --ask` that gave up waits for nothing anymore.
        if request.agent == .other, !requests.contains(where: { $0.sessionID == request.sessionID }),
           let index = sessions.firstIndex(where: { $0.id == request.sessionID }) {
            sessions[index].state = .idle
        }
        Hub.shared.refresh()
    }

    /// Lab only.
    func preview(_ request: Request?, sessions: [Session]) {
        isPreview = true
        requests = request.map { [$0] } ?? []
        self.sessions = sessions
        Hub.shared.refresh()
    }

    func preview(requests: [Request], sessions: [Session]) {
        isPreview = true
        self.requests = requests
        self.sessions = sessions
        navigation.openOldest()
        Hub.shared.refresh()
    }
}

/// Soft system sounds, and only if you want sounds.
enum Sounds {
    enum Kind {
        case question, done
    }

    static func play(_ kind: Kind) {
        guard UserDefaults.standard.bool(forKey: Preferences.playsSounds) else { return }
        let sound = NSSound(named: kind == .question ? "Tink" : "Pop")
        sound?.volume = kind == .question ? 0.35 : 0.25
        sound?.play()
    }
}
