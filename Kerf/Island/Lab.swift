import AppKit
import KerfKit
import SwiftUI

/// Checks the island without real data or permissions.
///
///     Kerf --lab motion <dir>         the iPhone recording's script, every frame saved
///     Kerf --lab shot <scene> <file>  one settled frame of a scene (see `scenes`)
///     Kerf --lab levels <seconds> [tap] [synth]
///                                     music with moving bars, to measure what that costs; with
///                                     `tap` the real system audio tap runs too (start it with
///                                     `open -n`, so macOS asks Kerf's permission, not the shell's),
///                                     and `synth` puts a music-like test signal in what it hears
///     Kerf --lab workflows            checks queue, drafts and branch labels without real sessions
struct Lab {
    enum Job {
        case motion(URL)
        case shot(String, URL)
        /// Opens with the keyboard, switches to another app, closes: logs whether the island stays.
        case focus
        case workflows
        /// Writes an app's menu titles and the room they leave beside the notch to a file.
        case menus(pid: pid_t, file: URL)
        case levels(seconds: Double, tap: Bool, synth: Bool)
    }

    let job: Job

    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--lab"), arguments.count > index + 1 else { return nil }
        if arguments[index + 1] == "focus" {
            job = .focus
            return
        }
        if arguments[index + 1] == "workflows" {
            job = .workflows
            return
        }
        guard arguments.count > index + 2 else { return nil }
        switch arguments[index + 1] {
        case "motion": job = .motion(URL(fileURLWithPath: arguments[index + 2]))
        case "shot" where arguments.count > index + 3: job = .shot(arguments[index + 2], URL(fileURLWithPath: arguments[index + 3]))
        case "menus" where arguments.count > index + 3:
            job = .menus(pid: pid_t(arguments[index + 2]) ?? 0, file: URL(fileURLWithPath: arguments[index + 3]))
        case "levels":
            let options = arguments.dropFirst(index + 3)
            job = .levels(seconds: Double(arguments[index + 2]) ?? 20, tap: options.contains("tap"), synth: options.contains("synth"))
        default: return nil
        }
    }

    /// Scenes for `shot`: set up an island, then it settles for a second and a half.
    static let scenes: [String: @MainActor (IslandController) -> Void] = [
        "idle": { _ in },
        // A fresh install: only the agents, none connected yet.
        "fresh": { controller in
            FeatureSwitches.shared.preview(only: [.agents])
            AgentCenter.shared.previewUnconnected()
            Hub.shared.refresh()
            controller.open()
        },
        // Settings → Features on a fresh install; `settings-` scenes save the Settings window.
        "settings-fresh": { _ in
            FeatureSwitches.shared.preview(only: [.agents])
            SettingsOpener.open(tab: .features)
        },
        "settings-general": { _ in SettingsOpener.open(tab: .general) },
        "settings-pages": { _ in SettingsOpener.open(tab: .pages) },
        // The agents with GitHub and Ask, nothing else: the bar holds only their pages.
        "coding": { controller in
            FeatureSwitches.shared.preview(only: [.agents, .github, .ask])
            AgentCenter.shared.preview(nil, sessions: sampleSessions)
            Hub.shared.refresh()
            controller.open()
        },
        "banner": { $0.island.show(.banner(.symbol("battery.100percent.bolt", .green), .value("80%")), waiting: 0) },
        "dot": { $0.island.show(nil, waiting: 1) },
        // Three threads blocked on you: the dot with its count.
        "dot-count": { _ in
            var sessions = sampleSessions
            for index in sessions.indices { sessions[index].state = .waiting }
            AgentCenter.shared.preview(nil, sessions: sessions)
        },
        "today": { controller in
            WeatherModule.shared.preview(.init(temperature: 11.4, symbol: "cloud.sun.fill", rainAt: .now.addingTimeInterval(5400)))
            let hour: TimeInterval = 3600
            CalendarModule.shared.preview([
                .init(title: "Montage Bruiloft de Vries", start: .now - 3 * hour, end: .now - 1.5 * hour, color: Color(nsColor: .systemOrange), id: "1"),
                .init(title: "Lunch met Sanne", start: .now - hour, end: .now - 0.25 * hour, color: Color(nsColor: .systemGreen), id: "2"),
                .init(title: "Call met Jansen over de trouwfilm", start: .now + 720, end: .now + 2520, color: Color(nsColor: .systemBlue),
                      joinURL: URL(string: "https://meet.google.com/abc"), id: "3"),
                .init(title: "Kleurcorrectie FX3-beelden", start: .now + 1.5 * hour, end: .now + 3 * hour, color: Color(nsColor: .systemPurple), id: "4"),
                .init(title: "Sportschool", start: .now + 4 * hour, end: .now + 5 * hour, color: Color(nsColor: .systemGreen), id: "5"),
            ])
            controller.open(page: .today)
        },
        "music": { _ in previewMusic() },
        "music-open": { previewMusic(); $0.open(page: .music) },
        "home": { controller in
            previewMusic()
            Self.scenes["today"]?(controller)
            controller.open(page: .home)
        },
        "volume": { _ in Hub.shared.show(.volume, 0.62, seconds: 10) },
        "brightness": { _ in Hub.shared.show(.brightness, 0.8, seconds: 10) },
        "agent": { _ in previewAgent(question: false) },
        "agent-copilot": { controller in
            previewAgent(question: false, agent: .copilot)
            controller.open(page: .agents)
        },
        "card": { _ in previewOffload(.card) },
        "ask": { $0.open(page: .ask) },
        "timer": { _ in TimerModule.shared.start(295) },
        "clipboard": { controller in
            ShelfModule.shared.showsClipboard = true
            ClipboardModule.shared.preview(["Bruiloft Jansen, 12 juni, Kasteel de Haar", "https://example.com/projects/42", "S-Log3 + S-Gamut3.Cine"])
            controller.open(page: .shelf)
        },
        "github-branches": { controller in
            Task {
                await GitHubModule.shared.refresh()
                GitHubModule.shared.tab = .branches
                await GitHubModule.shared.loadGraph()
                controller.open(page: .github)
            }
        },
        "github-pulls": { controller in
            Task {
                await GitHubModule.shared.refresh()
                GitHubModule.shared.tab = .pulls
                controller.open(page: .github)
            }
        },
        "github": { controller in
            Task {
                await GitHubModule.shared.refresh()
                GitHubModule.shared.tab = .files
                await GitHubModule.shared.loadTree()
                controller.open(page: .github)
            }
        },
        "shelf": { controller in
            ShelfModule.shared.preview(["/System/Applications/Notes.app", "/System/Library/Desktop Pictures", "/etc/hosts"].map { URL(fileURLWithPath: $0) })
            controller.open(page: .shelf)
        },
        "shelf-drop": { controller in
            ShelfModule.shared.isDropping = true
            controller.open(page: .shelf)
        },
        "ask-answer": { controller in
            AskModule.shared.preview(question: "Welk kleurprofiel voor trouwfilms bij weinig licht?",
                                     answer: "Gebruik **S-Log3** met **S-Gamut3.Cine** op je FX3, en belicht 1 tot 1,5 stop over.\n\n- ISO 800 of 12800 (dual base)\n- Houd de huid rond 55 tot 60 IRE\n- Kleur bij in Resolve met een CST naar Rec.709")
            controller.open(page: .ask)
        },
        "card-open": { previewOffload(.card); $0.open() },
        "card-drive": { previewOffload(.drive); $0.open() },
        "card-project": { controller in
            previewOffload(.project(.init(url: URL(fileURLWithPath: "/Volumes/Werk SSD"), name: "Werk SSD", free: 1_240_000_000_000)))
            controller.open()
        },
        "card-copying": { previewOffload(.copying); $0.open() },
        "card-copying-compact": { _ in previewOffload(.copying) },
        "card-done": { previewOffload(.done); $0.open() },
        "agent-open": { previewAgent(question: false); $0.open() },
        "agent-question": { previewAgent(question: true); $0.open() },
        "agent-question-draft": { controller in
            previewAgent(question: true)
            if let id = AgentCenter.shared.requests.first?.id {
                var draft = QuestionDraft()
                draft.typed = "Keep the existing folder names"
                AgentCenter.shared.questionDrafts[id] = draft
                AgentCenter.shared.navigation.overview()
            }
            controller.open()
        },
        "agent-question-long": { previewLongQuestion(); $0.open() },
        "agent-long": { previewLongCommand(); $0.open() },
        // The island is open on the threads when a question comes in: it must grow to fit.
        "agent-arrives": { controller in
            AgentCenter.shared.preview(nil, sessions: sampleSessions)
            controller.open(page: .agents)
            Task {
                try? await Task.sleep(for: .seconds(0.6))
                previewLongQuestion()
            }
        },
        // Today first, then the AI page with a question waiting.
        "agent-switch": { controller in
            controller.open(page: .today)
            Task {
                try? await Task.sleep(for: .seconds(0.5))
                previewLongQuestion()
                controller.island.select(.agents)
            }
        },
        // A thread that stopped on a rate limit: the red triangle instead of the tick.
        "agent-failed": { _ in
            var failed = AgentCenter.Session(id: "4", agent: .claudeCode, name: "Claude Code", hostPath: t3, project: "kerf", state: .idle,
                                             updated: .now, lastMessage: nil, title: "Port the waiting dot", unread: true)
            failed.needsInput = true
            failed.failure = "rate_limit"
            AgentCenter.shared.preview(nil, sessions: [failed])
        },
        "agent-sessions": { controller in
            AgentCenter.shared.preview(nil, sessions: sampleSessions)
            previewPulls()
            controller.open(page: .agents)
        },
        "timer-page": { $0.open(page: .timer) },
        "timer-running": { controller in
            TimerModule.shared.start(1500)
            TimerModule.shared.start(300)
            controller.open(page: .timer)
        },
        "more": { $0.open(page: .more) },
        "mixer": { controller in
            AppMixer.shared.refresh()
            controller.open(page: .mixer)
        },
        "ask-typed": { controller in
            AskModule.shared.text = "Hoe exporteer ik een proxy in Resolve"
            controller.open(page: .ask, keyboard: true)
        },
        "agent-queue": { controller in
            previewQueue()
            controller.open(page: .agents)
        },
        "agent-thread-answer": { controller in
            previewQueue()
            controller.open(page: .agents)
            let center = AgentCenter.shared
            center.navigation.overview()
            if let session = center.sessions.first(where: { $0.id == "4" }), let request = center.request(for: session) {
                center.navigation.select(request.id)
            }
        },
        "agent-queue-overview": { controller in
            previewQueue()
            previewPulls()
            controller.open(page: .agents)
            AgentCenter.shared.navigation.overview()
        },
        "pull-alert": { _ in
            AgentCenter.shared.preview(nil, sessions: [])
            previewPullAlert()
        },
        "pull-alert-open": { controller in
            AgentCenter.shared.preview(nil, sessions: [])
            previewPullAlert()
            controller.open(page: .agents)
        },
    ]

    static func previewQueue() {
        // A second kerf thread, on another branch.
        var sessions = sampleSessions + [AgentCenter.Session(id: "4", agent: .claudeCode, name: "Claude Code", hostPath: t3, project: "kerf",
                                                             state: .waiting, updated: .now, lastMessage: nil, title: "Port the waiting dot", unread: false)]
        for index in sessions.indices {
            switch sessions[index].id {
            case "1": sessions[index].repository = .init(id: "/kerf/.git", branch: "v1-agentic", revision: "", repositories: ["octocat/kerf"])
            case "4": sessions[index].repository = .init(id: "/kerf/.git", branch: "fix/waiting-dot", revision: "", repositories: ["octocat/kerf"])
            default: break
            }
        }
        let requests = ["1", "4"].map { id in
            AgentCenter.Request(sessionID: id, agent: .claudeCode, name: "Claude Code", hostPath: t3,
                                project: "kerf", cwd: "/Users/me/GitHub/kerf",
                                event: .permission(tool: "Bash", input: .object(["command": .string(id == "1" ? "swift test" : "git diff --stat")]), suggestions: []),
                                connection: nil)
        }
        for index in sessions.indices where ["1", "4"].contains(sessions[index].id) {
            sessions[index].state = .waiting
            sessions[index].failure = nil
            sessions[index].needsInput = false
        }
        AgentCenter.shared.preview(requests: requests, sessions: sessions)
    }

    static func previewPullAlert() {
        previewPulls()
        var baseline = GitHubModule.shared.pulls
        for index in baseline.indices {
            baseline[index].checks = .passing
            baseline[index].changesRequested = false
        }
        GitHubModule.shared.preview(pulls: baseline, changed: GitHubModule.shared.pulls)
    }

    static let t3 = "/Applications/T3 Code (Nightly).app"

    static let sampleCard = CameraCard(brand: "Sony", model: "FX3", kind: .video,
                                       files: [CardFile(path: "PRIVATE/M4ROOT/CLIP/C0001.MP4", size: 128_400_000_000)], mediaCount: 142)

    static func previewOffload(_ step: OffloadModule.Step) {
        let drive = OffloadModule.Drive(url: URL(fileURLWithPath: "/Volumes/Werk SSD"), name: "Werk SSD", free: 1_240_000_000_000)
        OffloadModule.shared.preview(
            card: sampleCard, step: step,
            progress: .init(copiedBytes: 52_000_000_000, totalBytes: 128_400_000_000, filesDone: 58, filesTotal: 142, skipped: 0,
                            currentFile: "C0058.MP4", bytesPerSecond: 812_000_000),
            report: .init(copied: 142, skipped: 0, bytes: 128_400_000_000, cardFolder: URL(fileURLWithPath: "/Volumes/Werk SSD/Projecten/Bruiloft Jansen/Beelden/Sony FX3/Kaart 02"), mismatches: []),
            drives: [drive, .init(url: URL(fileURLWithPath: "/Volumes/Backup"), name: "Backup", free: 3_100_000_000_000)],
            projects: ["Bruiloft Jansen", "Bedrijfsfilm Vos"])
    }

    static var sampleSessions: [AgentCenter.Session] {
        var sessions: [AgentCenter.Session] = [
            .init(id: "1", agent: .claudeCode, name: "Claude Code", hostPath: t3, project: "kerf", state: .working, updated: .now,
                  lastMessage: nil, title: "Make the timer its own tab", unread: false),
            .init(id: "2", agent: .claudeCode, name: "Claude Code", hostPath: "/System/Applications/Utilities/Terminal.app", project: "atlas",
                  state: .idle, updated: .now.addingTimeInterval(-600), lastMessage: "Tests pass.", title: "Fix the sync check-in", unread: true),
            .init(id: "3", agent: .codex, name: "Codex", hostPath: t3, project: "tempo", state: .waiting, updated: .now,
                  lastMessage: nil, title: "Review the weekly summary", unread: false),
        ]
        sessions[0].subagents = ["a", "b"]
        // How long each has worked, been done or waited.
        for (index, minutes) in [41.0, 10, 12].enumerated() { sessions[index].stateSince = .now.addingTimeInterval(-minutes * 60) }
        return sessions
    }

    static func previewPulls() {
        let json = #"[{"number":42,"title":"Kerf: AI tab with threads","repository":{"nameWithOwner":"octocat/kerf"},"url":"https://github.com/octocat/kerf/pull/42","updatedAt":"2026-10-31T10:00:00Z","isDraft":false,"checks":"failing"},{"number":17,"title":"Weekly summary in Tempo","repository":{"nameWithOwner":"octocat/tempo"},"url":"https://github.com/octocat/tempo/pull/17","updatedAt":"2026-10-30T18:00:00Z","isDraft":true,"checks":"pending","changesRequested":true},{"number":8,"title":"Dark mode for the dashboard","repository":{"nameWithOwner":"octocat/atlas"},"url":"https://github.com/octocat/atlas/pull/8","updatedAt":"2026-11-01T09:00:00Z","isDraft":false,"checks":"passing","reviewRequested":true}]"#
        GitHubModule.shared.preview(pulls: GitHub.decode([GitHub.Item].self, from: Data(json.utf8)) ?? [])
    }

    static func previewAgent(question: Bool, agent: AgentKind = .claudeCode) {
        let payload: JSONValue = question
            ? .object(["hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "cwd": "/Users/me/GitHub/kerf",
                       "tool_input": .object(["questions": .array([.object([
                           "question": "Which folder names for a project?", "header": "Folders", "multiSelect": .bool(false),
                           "options": .array([.object(["label": "Short, no numbers"]), .object(["label": "Numbered Dutch"]),
                                              .object(["label": "Numbered English"]), .object(["label": "Client / Project"])]),
                       ])])])])
            : .object(["hook_event_name": "PermissionRequest", "tool_name": "Bash", "cwd": "/Users/me/GitHub/atlas",
                       "tool_input": .object(["command": "xcodebuild -project Atlas.xcodeproj -scheme Atlas test"])])
        let request = AgentCenter.Request(sessionID: "1", agent: agent, name: agent.displayName, hostPath: t3, project: payload.project,
                                          cwd: payload.workingDirectory, event: AgentEvent(payload), connection: nil)
        AgentCenter.shared.preview(request, sessions: sampleSessions)
    }

    /// A question with more text than fits on a line, and options with descriptions.
    static func previewLongQuestion() {
        let options: [JSONValue] = [
            .object(["label": "Keep one version and drop the personal parts", "description": "Simplest to maintain. The removed code stays in git history if you ever want it back."]),
            .object(["label": "Two versions with a build setting", "description": "The public build leaves the personal parts out; your own build keeps them. More upkeep."]),
            .object(["label": "Decide later", "description": "Nothing changes now."]),
        ]
        let payload: JSONValue = .object(["hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "cwd": "/Users/me/GitHub/kerf",
            "tool_input": .object(["questions": .array([.object([
                "question": "The personal integrations are connected on your own Mac right now. What should happen to them in the version others install, and in your own copy?",
                "header": "Personal", "multiSelect": .bool(false), "options": .array(options),
            ])])])])
        let request = AgentCenter.Request(sessionID: "1", agent: .claudeCode, name: "Claude Code", hostPath: t3, project: payload.project,
                                          cwd: payload.workingDirectory, event: AgentEvent(payload), connection: nil)
        AgentCenter.shared.preview(request, sessions: sampleSessions)
    }

    /// A permission for a command too long for three lines.
    static func previewLongCommand() {
        let command = "cd ~/GitHub/kerf && xcodebuild -project Kerf.xcodeproj -scheme Kerf -configuration Release -derivedDataPath build/DerivedData archive -archivePath build/Kerf.xcarchive && xcodebuild -exportArchive -archivePath build/Kerf.xcarchive -exportOptionsPlist scripts/ExportOptions.plist -exportPath build/export -allowProvisioningUpdates && ditto -c -k --keepParent build/export/Kerf.app build/Kerf.zip && shasum -a 256 build/Kerf.zip"
        let payload: JSONValue = .object(["hook_event_name": "PermissionRequest", "tool_name": "Bash", "cwd": "/Users/me/GitHub/kerf",
                                          "tool_input": .object(["command": .string(command)])])
        let request = AgentCenter.Request(sessionID: "1", agent: .claudeCode, name: "Claude Code", hostPath: t3, project: payload.project,
                                          cwd: payload.workingDirectory, event: AgentEvent(payload), connection: nil)
        AgentCenter.shared.preview(request, sessions: sampleSessions)
    }

    static func previewMusic() {
        let state = NowPlayingState(title: "Nachtrit", artist: "Kerf", duration: 223, elapsed: 72, isPlaying: true,
                                    sourceBundleID: "com.spotify.client")
        NowPlayingModule.shared.preview(state, artwork: sampleArtwork(), tint: Color(red: 1, green: 0.42, blue: 0.62))
        AudioLevels.shared.preview([0.55, 0.9, 0.7, 0.45, 0.6, 0.3])
    }

    /// A gradient square standing in for album art.
    static func sampleArtwork() -> NSImage {
        NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            NSGradient(colors: [.systemOrange, .systemPink, .systemPurple])?.draw(in: rect, angle: -45)
            return true
        }
    }

    func run() {
        Preferences.register()
        // Real taps only for `levels … tap`, and every exit takes them down first.
        if case .levels(_, true, _) = job {} else { AudioLevels.shared.tapsAllowed = false }
        AppMixer.shared.tapsAllowed = false
        guard let screen = NSScreen.screens.first(where: { $0.notchSize != nil }) ?? NSScreen.main else { Self.quit(1) }
        let controller = IslandController(screen: screen, interactive: false)
        Hub.shared.observe { controller.apply(Hub.shared) }
        controller.apply(Hub.shared)
        controller.show()
        switch job {
        case .motion(let directory): motion(controller, directory)
        case .shot(let scene, let file): shot(controller, scene, file)
        case .focus: focus(controller)
        case .workflows: checkWorkflows(controller)
        case .menus(let pid, let file):
            let scan = MenuBarScan(front: pid, readMenus: true)
            let display = CGDisplayBounds(screen.displayID)
            let items = (scan.menuItems ?? []).filter { abs($0.minY - display.minY) < 2 } + scan.statusItems(on: display)
            var lines = (scan.menuItems ?? []).map { "menu \(Int($0.minX))...\(Int($0.maxX)) y \(Int($0.minY))" }
            lines += scan.statusItems(on: display).map { "status \(Int($0.minX))...\(Int($0.maxX))" }
            lines += scan.windows.filter { $0.pid == pid && $0.layer == 0 }.map { window in
                let hides = WindowVisibility.hidesIsland(window: window.bounds, display: display, notch: screen.safeAreaInsets.top,
                                                         isFullScreen: window.isFullScreen, dockShown: scan.dockFrames.contains { $0.intersects(display) })
                return "window \(window.bounds) fullScreen \(window.isFullScreen.map(String.init) ?? "unknown") hidesIsland \(hides)"
            }
            if let range = screen.notchRange {
                lines.append("notch \(Int(range.lowerBound))...\(Int(range.upperBound))")
                lines.append("room \(MenuBarRoom.free(notchMinX: range.lowerBound, notchMaxX: range.upperBound, items: items))")
            }
            try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            Self.quit(0)
        case .levels(let seconds, let tap, let synth):
            // Drawn and measured like the real island, but nobody sees a made-up song.
            controller.panel.alphaValue = 0.02
            levels(seconds: seconds, tap: tap, synth: synth)
        }
    }

    /// Without `tap`: made-up levels, 30 a second, the way the tap delivers them.
    private func levels(seconds: Double, tap: Bool, synth: Bool) {
        Task {
            try? await Task.sleep(for: .seconds(0.4))
            Self.previewMusic()
            if synth { TapEngine.labSignal = LabSignal(sampleRate: 48_000) }
            if tap {
                // pid=N taps that app, as with real music; otherwise everything.
                let target = CommandLine.arguments.first { $0.hasPrefix("pid=") }.flatMap { Int32($0.dropFirst(4)) }
                AudioLevels.shared.follow(processID: target, playing: true)
            } else {
                Self.feed = Self.makeFeed()
            }
            let start = TapEngine.labCycles
            try? await Task.sleep(for: .seconds(seconds))
            let cycles = Double(TapEngine.labCycles - start) / seconds
            let commits = BarLayers.commits
            let visible = NSApp.windows.contains { $0.occlusionState.contains(.visible) }
            try? "audio cycles per second: \(cycles), bar commits: \(commits), island visible: \(visible)\n".write(toFile: "/tmp/kerf_bench/lab.log", atomically: true, encoding: .utf8)
            AudioLevels.shared.stop()
            Self.quit(0)
        }
    }

    private static var feed: DispatchSourceTimer?

    /// A process that exits with a tap running can leave the audio daemon spinning: taps first.
    static func quit(_ status: Int32) -> Never {
        AudioLevels.shared.stop()
        AppMixer.shared.stopAll()
        exit(status)
    }

    /// Off the main thread like the tap; nonisolated, or Swift traps when the queue calls it.
    nonisolated private static func makeFeed() -> DispatchSourceTimer {
        let feed = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "nl.paulboerma.kerf.lab.levels"))
        let start = CACurrentMediaTime()
        feed.schedule(deadline: .now(), repeating: 1.0 / 30)
        feed.setEventHandler {
            let time = Float(CACurrentMediaTime() - start)
            let bars = (0..<LevelMeter.bars).map { band in
                let wave = sin(time * Float(3 + band) + Float(band)) * sin(time * 1.3 + Float(band) * 0.7)
                return 0.5 + 0.45 * wave
            }
            Task { @MainActor in AudioLevels.shared.preview(bars) }
        }
        feed.resume()
        return feed
    }

    private func checkWorkflows(_ controller: IslandController) {
        func check(_ condition: Bool, _ message: String) {
            guard condition else {
                print("FAIL: \(message)")
                Self.quit(1)
            }
        }
        let center = AgentCenter.shared
        Self.previewQueue()
        let original = center.requests
        controller.open(page: .agents)
        check(center.selectedRequest?.id == original[0].id, "Opening selects oldest")
        center.navigation.overview()
        check(center.selectedRequest == nil && center.requests.count == 2, "Overview keeps requests pending")
        for session in center.sessions {
            let request = center.request(for: session)
            check((request != nil) == ["1", "4"].contains(session.id), "Only answerable threads have an Answer action")
            if let request {
                center.navigation.select(request.id)
                check(center.selectedRequest?.sessionID == session.id, "Answer selects that thread's decision")
                center.navigation.overview()
            }
        }
        guard var session = center.sessions.first(where: { $0.id == "1" }) else {
            print("FAIL: missing preview session")
            Self.quit(1)
        }
        session.hostPath = nil
        center.open(session)
        check(center.navigation.showsOverview && center.requests.count == 2, "Opening a session never answers or selects a decision")
        center.navigation.select(original[0].id)
        var draft = QuestionDraft()
        draft.typed = "Keep this answer"
        draft.index = 1
        draft.answers = ["First question": "First answer"]
        draft.picked = ["Option A"]
        center.questionDrafts[original[0].id] = draft
        center.navigation.overview()
        center.navigation.select(original[1].id)
        center.navigation.overview()
        center.navigation.select(original[0].id)
        check(center.questionDrafts[original[0].id]?.typed == draft.typed, "Typed answer survives switching")
        check(center.questionDrafts[original[0].id]?.answers == draft.answers, "Earlier answers survive switching")
        check(center.questionDrafts[original[0].id]?.picked == draft.picked, "Selections survive switching")
        check(center.projectLabel(for: original[0]) == "kerf · v1-agentic", "Shared repository shows branch")
        center.answer(original[0], .init(decision: .allow))
        check(center.requests.count == 1 && center.selectedRequest?.id == original[1].id, "Answer advances selection")
        check(center.questionDrafts[original[0].id] == nil, "Answered draft is removed")
        center.navigation.overview()
        center.answer(original[1], .init(decision: .deny))
        check(center.requests.isEmpty && center.navigation.showsOverview, "Last answer leaves chosen overview")
        Self.previewQueue()
        let first = center.requests[0]
        let another = AgentCenter.Request(sessionID: first.sessionID, agent: first.agent, name: first.name,
                                          hostPath: first.hostPath, project: first.project, cwd: first.cwd,
                                          event: first.event, connection: nil)
        center.preview(requests: [first, another], sessions: center.sessions)
        center.answer(first, .init(decision: .deny))
        guard let waiting = center.visibleThreads.first(where: { $0.id == first.sessionID }) else {
            print("FAIL: thread with another pending decision disappeared")
            Self.quit(1)
        }
        check(waiting.state == .waiting && center.request(for: waiting)?.id == another.id,
              "Another pending decision keeps the thread waiting and answerable")
        guard var single = Self.sampleSessions.first(where: { $0.id == "1" }) else {
            print("FAIL: missing preview session")
            Self.quit(1)
        }
        single.repository = .init(id: "/kerf/.git", branch: "v1-agentic", revision: "", repositories: [])
        center.preview(nil, sessions: [single])
        check(center.projectLabel(for: single) == "kerf", "Single session hides branch")
        Self.previewQueue()
        center.navigation.select(center.requests[1].id)
        controller.close()
        controller.open(page: .agents)
        check(center.selectedRequest?.id == center.requests.first?.id, "Reopening resets to oldest")
        center.preview(nil, sessions: [])
        Self.previewPullAlert()
        check(GitHubModule.shared.attentionCount == 2, "PR transitions create two quiet alerts")
        check(Hub.shared.presentation?.kind == "pullNotice", "PR alerts reach the compact island")
        print("PASS: decision-first navigation, per-thread Answer actions, independent session links, draft retention, branches and PR presentation")
        Self.quit(0)
    }

    private func focus(_ controller: IslandController) {
        func log(_ step: String) {
            let panel = controller.panel
            print("\(step): visible \(panel.isVisible) key \(panel.isKeyWindow) onScreen \(panel.occlusionState.contains(.visible)) mode \(controller.island.mode) frame \(panel.frame.origin.y)")
        }
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            controller.open(page: .ask, keyboard: true)
            try? await Task.sleep(for: .seconds(1))
            log("open")
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
            try? await Task.sleep(for: .seconds(1))
            log("finder active")
            controller.close()
            try? await Task.sleep(for: .seconds(1))
            log("closed")
            Self.quit(0)
        }
    }

    private func shot(_ controller: IslandController, _ scene: String, _ file: URL) {
        guard let setUp = Self.scenes[scene] else {
            print("Unknown scene \(scene). Scenes: \(Self.scenes.keys.sorted().joined(separator: ", "))")
            Self.quit(1)
        }
        Task {
            try? await Task.sleep(for: .seconds(0.4))
            setUp(controller)
            if ProcessInfo.processInfo.environment["KERF_LAB_DEBUG"] != nil {
                try? await Task.sleep(for: .seconds(0.3))
                print("page \(controller.island.page) pages \(controller.island.pages) more \(Hub.shared.morePages)")
            }
            // Scenes with real data (gh) need longer.
            try? await Task.sleep(for: .seconds(scene.hasPrefix("github") ? 8 : 1.6))
            let window = scene.hasPrefix("settings-")
                ? NSApp.windows.first { $0 !== controller.panel && $0.isVisible && $0.styleMask.contains(.titled) } : controller.panel
            if let window, let image = FrameRecorder.snapshot(of: window) { writePNG(image, to: file) }
            Self.quit(0)
        }
    }

    private func motion(_ controller: IslandController, _ directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let recorder = FrameRecorder(window: controller.panel, directory: directory)
        let script: [(Double, String, () -> Void)] = [
            (1, "compact", { Self.previewMusic() }),
            (3, "expanded", { controller.open() }),
            (6, "compact", { controller.close() }),
            (8, "expanded", { controller.open() }),
            (11, "compact", { controller.close() }),
            (13, "idle", { NowPlayingModule.shared.preview(nil, artwork: nil, tint: .pink) }),
        ]
        Task {
            try? await Task.sleep(for: .seconds(0.6))
            recorder.begin()
            let clock = ContinuousClock()
            let start = clock.now
            for (time, name, step) in script {
                try? await clock.sleep(until: start + .seconds(time))
                recorder.mark(name)
                step()
            }
            try? await clock.sleep(until: start + .seconds(14.5))
            recorder.finish()
            Self.quit(0)
        }
    }
}

/// Something like a song for the lab: a kick, hi-hats, chords and a melody, so all six bars move
/// the way they do with music. Made once, then copied, so making it costs nothing per buffer.
nonisolated final class LabSignal: @unchecked Sendable {
    private let samples: [Float]
    private var position = 0

    init(sampleRate: Float) {
        let count = Int(sampleRate * 8)
        let chords: [[Float]] = [[220, 277.2, 329.6], [196, 246.9, 293.7], [174.6, 220, 261.6], [196, 246.9, 311.1]]
        let melody: [Float] = [880, 987.8, 1108.7, 1318.5, 1174.7, 987.8, 880, 1661.2]
        var noise: UInt32 = 0x1234_5678
        var lastNoise: Float = 0
        samples = (0..<count).map { index in
            let time = Float(index) / sampleRate
            let beat = time.truncatingRemainder(dividingBy: 0.5)
            let kick = sin(2 * .pi * 55 * beat) * exp(-beat * 18) * 0.9
            noise = noise &* 1_664_525 &+ 1_013_904_223
            let white = Float(noise >> 8) / Float(1 << 24) * 2 - 1
            let hat = (white - lastNoise) * exp(-time.truncatingRemainder(dividingBy: 0.25) * 40) * 0.35
            lastNoise = white
            let chord = chords[Int(time / 2) % chords.count].reduce(0) { $0 + sin(2 * .pi * $1 * time) } * 0.12
            let note = sin(2 * .pi * melody[Int(time * 4) % melody.count] * time) * 0.15 * (0.6 + 0.4 * sin(time * 3))
            return kick + hat + chord + note
        }
    }

    func fill(_ buffer: UnsafeMutableBufferPointer<Float>) {
        for index in buffer.indices {
            buffer[index] = samples[position]
            position = position + 1 == samples.count ? 0 : position + 1
        }
    }
}
