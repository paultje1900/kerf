import AppKit
import KerfKit
import SwiftUI

/// How much of your Claude plan is used, for the rings beside the notch: the 5-hour session, the
/// week, and the week for one model. Asked from your own Claude Code the way its /usage asks:
/// no prompt goes out and it costs nothing of the plan.
@Observable
final class ClaudeUsageModule {
    static let shared = ClaudeUsageModule()

    enum Status: Equatable {
        case asking, known, notInstalled
        /// Claude Code answered without limits: an API key, not signed in, or a version before /usage.
        case unavailable
    }

    private(set) var usage: ClaudeUsage?
    private(set) var status = Status.asking
    private(set) var side = UsageSide(rawValue: UserDefaults.standard.string(forKey: Preferences.usageSide) ?? "") ?? .right
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var lastAsked = Date.distantPast
    @ObservationIgnored private var isAsking = false
    @ObservationIgnored private var planned: Task<Void, Never>?
    @ObservationIgnored private var isRunning = false

    /// A thread's turn changes the numbers at once; otherwise they only move with what you do
    /// elsewhere, or when a limit starts over.
    private static let interval: TimeInterval = 600
    private static let shortest: TimeInterval = 60

    /// The rings as the island shows them; nil while switched off or nothing is known.
    var strip: UsageStrip? {
        guard Feature.usage.isOn, let usage, !usage.limits.isEmpty else { return nil }
        return UsageStrip(side: side, count: usage.limits.count)
    }

    func setSide(_ new: UsageSide) {
        side = new
        UserDefaults.standard.set(new.rawValue, forKey: Preferences.usageSide)
        Hub.shared.refresh()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        ask()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { ClaudeUsageModule.shared.askIfSeen() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ClaudeUsageModule.shared.askIfSeen() }
        }
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        planned?.cancel()
        planned = nil
        usage = nil
        status = .asking
    }

    /// A Claude Code thread finished a turn: the numbers moved. At most once a minute.
    func turnEnded() {
        guard isRunning else { return }
        plan(at: max(Date.now.addingTimeInterval(3), lastAsked.addingTimeInterval(Self.shortest)))
    }

    /// Nobody sees the rings on a sleeping or locked screen: then nothing is asked.
    private func askIfSeen() {
        guard CGDisplayIsAsleep(CGMainDisplayID()) == 0, IslandManager.current?.isScreenCovered != true,
              Date.now.timeIntervalSince(lastAsked) >= Self.interval - 5 else { return }
        ask()
    }

    private func plan(at date: Date) {
        planned?.cancel()
        planned = Task {
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            ask()
        }
    }

    private func ask() {
        guard isRunning, !isAsking else { return }
        guard let executable = AskModule.claudeExecutable() else {
            status = .notInstalled
            return
        }
        isAsking = true
        lastAsked = .now
        Task {
            let answer = await Self.answer(from: executable)
            isAsking = false
            guard isRunning else { return }
            switch answer {
            case .limits(let new):
                let merged = new.keepingModel(from: usage)
                if merged != usage { usage = merged }
                status = .known
                // A ring empties when its limit starts over: look again right after.
                if let reset = merged.nextReset(after: .now) { plan(at: reset.addingTimeInterval(5)) }
            case .unavailable:
                usage = nil
                status = .unavailable
            case nil:
                // No answer this time (offline, or Claude Code was busy updating): keep what's known.
                break
            }
            Hub.shared.refresh()
        }
    }

    /// Starts Claude Code without a prompt, asks its control channel for the limits, and lets it go.
    nonisolated private static func answer(from executable: String) async -> ClaudeUsage.Answer? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            try? FileManager.default.createDirectory(at: AskModule.workFolder, withIntermediateDirectories: true)
            process.currentDirectoryURL = AskModule.workFolder
            process.arguments = [
                "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--no-session-persistence",
                // Like Ask: Kerf's own calls don't set off Kerf's hooks, or load MCP servers.
                "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config",
            ]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
            process.environment = environment
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            // It answers within two seconds; a Claude Code that hangs doesn't stay around.
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if process.isRunning { process.terminate() } }
            input.fileHandleForWriting.write(Data((ClaudeUsage.request + "\n").utf8))
            try? input.fileHandleForWriting.close()
            let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            return data.split(separator: UInt8(ascii: "\n")).lazy.compactMap { ClaudeUsage.answer(in: Data($0)) }.first
        }.value
    }

    /// Lab only.
    func preview(_ usage: ClaudeUsage?, side: UsageSide = .right) {
        self.usage = usage
        self.side = side
        status = usage == nil ? .unavailable : .known
        Hub.shared.refresh()
    }
}
