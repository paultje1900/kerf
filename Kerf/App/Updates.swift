import AppKit
import KerfKit
import SwiftUI

/// The notes this build came with, from `WhatsNew/` in the repository, and which ones you've seen.
enum WhatsNew {
    static let notes: [PatchNote] = {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("WhatsNew"),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return PatchNote.newestFirst(files.compactMap { file in
            (try? Data(contentsOf: file)).flatMap { PatchNote.parse(fileName: file.lastPathComponent, data: $0) }
        })
    }()

    static var seen: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Preferences.seenNotes) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: Preferences.seenNotes) }
    }

    static func markSeen(_ notes: [PatchNote]) { seen.formUnion(notes.map(\.id)) }

    /// Notes are in English and Dutch, like the app.
    static var language: String { Bundle.main.preferredLocalizations.first ?? "en" }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    /// What's new since you last looked, in a window. A fresh install has seen it all; right after
    /// an update you read them before you pressed Update, so the notch only says it's done.
    static func showAtLaunch(firstLaunch: Bool) {
        if firstLaunch { markSeen(notes) }
        let started = UserDefaults.standard.object(forKey: Preferences.updateStarted) as? Date
        UserDefaults.standard.removeObject(forKey: Preferences.updateStarted)
        let unseen = notes.filter { !seen.contains($0.id) }
        Task {
            try? await Task.sleep(for: .seconds(2))
            if let started, Date.now.timeIntervalSince(started) < 30 * 60 {
                Hub.shared.flash(.banner(.symbol("checkmark.circle.fill", Color(nsColor: .systemGreen)), .value(version)), seconds: 4)
            }
            guard !unseen.isEmpty else { return }
            markSeen(unseen)
            WhatsNewWindow.show(.notes(unseen))
        }
    }
}

/// Finds a newer Kerf and installs it, for copies built with `scripts/install.sh`: in the clone
/// it came from, `git fetch` says whether `main` has notes this build lacks; Update pulls and runs
/// the script again. Kerf only reaches GitHub through your own git, and only for this.
@Observable
final class Updater {
    static let shared = Updater()

    enum State: Equatable {
        case idle, checking, upToDate
        /// The clone's `main` on GitHub has more, and this is what it brings.
        case available([PatchNote])
        case updating
        case failed(Failure)
    }

    enum Failure: Equatable {
        case offline
        case branch(String)
        case changes
        case pull
        case build
    }

    private(set) var state = State.idle
    /// The clone this copy was built from; nil when it wasn't built by `scripts/install.sh` into
    /// /Applications (or ~/Applications), or the clone is gone.
    private(set) var source: URL? = {
        let path = Bundle.main.object(forInfoDictionaryKey: "KerfSource") as? String ?? ""
        guard !path.isEmpty, LoginItem.isInstalled,
              FileManager.default.fileExists(atPath: path + "/scripts/install.sh"),
              FileManager.default.fileExists(atPath: path + "/.git") else { return nil }
        return URL(fileURLWithPath: path)
    }()
    private let team = Bundle.main.object(forInfoDictionaryKey: "KerfTeam") as? String ?? ""
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastChecked = Date.distantPast

    /// A few times a day is plenty: nobody needs a new Kerf within the hour.
    private static let interval: TimeInterval = 6 * 3_600
    static let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Kerf/update.log")

    var sourcePath: String { source.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "" }

    func start() {
        guard source != nil, timer == nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(30))
            checkIfDue()
        }
        // Hourly, so a Mac that slept through a check catches up soon after it wakes.
        timer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard UserDefaults.standard.bool(forKey: Preferences.checksForUpdates), CGDisplayIsAsleep(CGMainDisplayID()) == 0,
              Date.now.timeIntervalSince(lastChecked) >= Self.interval - 60 else { return }
        check()
    }

    /// From the menu or Settings it shows what it finds, also when there's nothing; on its own
    /// it only shows an update with notes you haven't seen.
    func check(manual: Bool = false) {
        if manual { WhatsNewWindow.show(.update, activate: true) }
        guard let source, state != .checking, state != .updating else { return }
        let before = state
        state = .checking
        lastChecked = .now
        let installed = Set(WhatsNew.notes.map(\.id))
        Task {
            guard let notes = await Self.newNotes(in: source, installed: installed) else {
                if manual {
                    state = .failed(.offline)
                } else if case .available = before {
                    state = before
                } else {
                    state = .idle
                }
                return
            }
            state = notes.isEmpty ? .upToDate : .available(notes)
            let unseen = notes.filter { !WhatsNew.seen.contains($0.id) }
            guard !unseen.isEmpty else { return }
            WhatsNew.markSeen(notes)
            if !manual { WhatsNewWindow.show(.update) }
        }
    }

    func update() {
        guard let source, case .available = state else { return }
        state = .updating
        Task {
            if let failure = await Self.pull(source) {
                state = .failed(failure)
                return
            }
            do {
                try install(from: source)
            } catch {
                state = .failed(.build)
            }
        }
    }

    /// Runs `scripts/install.sh` on its own: it builds, then quits this Kerf and starts the new one.
    /// Its output goes to a file, as a pipe would break when this Kerf quits halfway.
    private func install(from source: URL) throws {
        try FileManager.default.createDirectory(at: Self.logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Self.logFile.path, contents: nil)
        let log = try FileHandle(forWritingTo: Self.logFile)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [source.appendingPathComponent("scripts/install.sh").path] + (team.isEmpty ? [] : ["DEVELOPMENT_TEAM=\(team)"])
        process.currentDirectoryURL = source
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { process in
            // Still here to hear it: the script stopped before it got to quitting this Kerf.
            let status = process.terminationStatus
            Task { @MainActor in
                Updater.shared.state = status == 0 ? .idle : .failed(.build)
                if status != 0 { WhatsNewWindow.show(.update) }
            }
        }
        UserDefaults.standard.set(Date.now, forKey: Preferences.updateStarted)
        try process.run()
    }

    /// The notes on GitHub's `main` that this build doesn't have; nil when git can't reach it.
    nonisolated static func newNotes(in source: URL, installed: Set<String>) async -> [PatchNote]? {
        await Task.detached(priority: .utility) {
            guard git(["fetch", "--quiet", "origin", "main"], in: source, timeout: 60) != nil,
                  let listing = git(["ls-tree", "--name-only", "origin/main", "WhatsNew/"], in: source) else { return nil }
            return PatchNote.newestFirst(PatchNoteUpdate.newFiles(listing: listing, installed: installed).compactMap { path in
                git(["show", "origin/main:\(path)"], in: source).flatMap { PatchNote.parse(fileName: path, data: Data($0.utf8)) }
            })
        }.value
    }

    /// Brings the clone up to `main`, only when that can't lose anything of yours.
    nonisolated private static func pull(_ source: URL) async -> Failure? {
        await Task.detached(priority: .userInitiated) {
            guard let branch = git(["rev-parse", "--abbrev-ref", "HEAD"], in: source)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return .pull }
            guard branch == "main" else { return .branch(branch) }
            guard git(["status", "--porcelain", "--untracked-files=no"], in: source)?.isEmpty == true else { return .changes }
            return git(["pull", "--ff-only", "--quiet", "origin", "main"], in: source, timeout: 120) == nil ? .pull : nil
        }.value
    }

    nonisolated private static func git(_ arguments: [String], in folder: URL, timeout: TimeInterval = 20) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        // Never wait for a password nobody sees.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// Lab only.
    func preview(_ state: State, source: URL? = nil) {
        self.state = state
        if let source { self.source = source }
    }
}

enum WhatsNewContent: Equatable {
    /// What came with this update.
    case notes([PatchNote])
    /// Every note this build has.
    case all
    /// What the updater found, and its Update button.
    case update
}

/// One window for what's new and for updates. It comes up without taking the keyboard from what
/// you're typing in, unless you asked for it.
enum WhatsNewWindow {
    private static var window: NSWindow?

    static func show(_ content: WhatsNewContent, activate: Bool = false) {
        let host = ClickThroughHostingView(rootView: WhatsNewView(content: content) { window?.close() })
        let window = window ?? {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.title = String(localized: "What's New in Kerf")
            return window
        }()
        Self.window = window
        let wasVisible = window.isVisible
        window.contentView = host
        if !wasVisible { window.center() }
        if activate { NSApp.activate() }
        window.orderFrontRegardless()
    }
}

struct WhatsNewView: View {
    let content: WhatsNewContent
    let close: () -> Void
    private let updater = Updater.shared

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                // Kerf has no app icon: the mark from the menu bar.
                Image(systemName: "capsule.tophalf.filled")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .frame(height: 56)
                Text(title).font(.title2.bold())
                if let subtitle {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !notes.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(notes) { PatchNoteRow(note: $0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 440)
                .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(width: 460)
    }

    private var notes: [PatchNote] {
        switch content {
        case .notes(let notes): notes
        case .all: WhatsNew.notes
        case .update: if case .available(let notes) = updater.state { notes } else { [] }
        }
    }

    private var title: LocalizedStringKey {
        guard content == .update else { return "What's New in Kerf" }
        return switch updater.state {
        case .idle, .checking: "Checking for Updates…"
        case .upToDate: "Kerf Is Up to Date"
        case .available: "A New Kerf Is Ready"
        case .updating: "Updating Kerf…"
        case .failed: "Kerf Couldn't Update"
        }
    }

    private var subtitle: String? {
        let folder = updater.sourcePath
        guard content == .update else { return String(localized: "Kerf \(WhatsNew.version)") }
        return switch updater.state {
        case .idle, .checking: nil
        case .upToDate: String(localized: "You have the newest version from \(folder).")
        case .available: String(localized: "Update builds it from \(folder) and restarts Kerf. That takes a minute or two.")
        case .updating: String(localized: "Building the new Kerf. It restarts by itself when it's done.")
        case .failed(.offline): String(localized: "Kerf couldn't reach GitHub. Check your connection and try again.")
        case .failed(.branch(let branch)):
            String(localized: "Your copy in \(folder) is on the branch \(branch). Switch to main, or update it yourself with git pull and scripts/install.sh.")
        case .failed(.changes):
            String(localized: "Your copy in \(folder) has changes of its own. Commit or stash them, or update it yourself with git pull and scripts/install.sh.")
        case .failed(.pull):
            String(localized: "git pull didn't work in \(folder). Update it yourself with git pull and scripts/install.sh.")
        case .failed(.build): String(localized: "The new Kerf didn't build. The log says why.")
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if content == .update {
                switch updater.state {
                case .available:
                    Spacer()
                    Button("Later", action: close).keyboardShortcut(.cancelAction)
                    Button("Update") { updater.update() }.keyboardShortcut(.defaultAction)
                case .idle, .checking, .updating:
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                case .failed(let failure):
                    if failure == .build {
                        Button("Show Log") { NSWorkspace.shared.open(Updater.logFile) }
                    }
                    Spacer()
                    Button("OK", action: close).keyboardShortcut(.defaultAction)
                case .upToDate:
                    Spacer()
                    Button("OK", action: close).keyboardShortcut(.defaultAction)
                }
            } else {
                Spacer()
                Button("Continue", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }
}

struct PatchNoteRow: View {
    let note: PatchNote

    var body: some View {
        let language = WhatsNew.language
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: note.title(in: language)).font(.headline)
                Text(verbatim: note.text(in: language))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let by = note.by {
                    Text("By \(by)").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// A name SF Symbols doesn't know would draw nothing.
    private var symbol: String {
        guard let name = note.symbol, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else { return "sparkles" }
        return name
    }
}
