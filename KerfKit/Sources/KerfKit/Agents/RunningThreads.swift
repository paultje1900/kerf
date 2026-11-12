import Darwin
import Foundation

/// Claude Code threads that were already busy when Kerf started. Hooks only say what happens
/// next, so a turn that began before Kerf did stays unseen until it ends. The running `claude`
/// processes and their transcripts fill that gap.
public enum RunningThreads {
    public struct Found: Equatable, Sendable {
        public var sessionID: String
        public var cwd: String
        public var hostPath: String?
        /// Its terminal, as `/dev/ttys003`.
        public var tty: String?
        public var title: String?
        public var updated: Date
    }

    /// Claude Code sessions in the middle of a turn.
    public static func claudeCode(projects: URL = ClaudeTranscript.projects, now: Date = .now) -> [Found] {
        let files = FileManager.default
        var claimed = Set<String>()
        var found: [Found] = []
        for pid in allProcesses() {
            guard let path = ProcessTree.executablePath(pid), URL(fileURLWithPath: path).lastPathComponent == "claude",
                  let cwd = workingDirectory(pid), let started = startDate(pid) else { continue }
            let arguments = arguments(pid)
            // One-shot calls, like Kerf's own Ask, are no threads.
            guard !arguments.contains("-p"), !arguments.contains("--print") else { continue }
            let folder = projects.appendingPathComponent(ClaudeTranscript.folderName(for: cwd), isDirectory: true)
            let named = ClaudeTranscript.sessionID(in: arguments).map { folder.appendingPathComponent("\($0).jsonl") }
            // The transcript it named, or the newest one written since it started.
            let candidates = (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let written = candidates
                .filter { $0.pathExtension == "jsonl" && !claimed.contains($0.path) }
                .compactMap { url in modified(url).map { (url: url, date: $0) } }
                .filter { $0.date >= started.addingTimeInterval(-5) }
                .sorted { $0.date > $1.date }
            guard let transcript = written.first(where: { $0.url == named }) ?? written.first else { continue }
            claimed.insert(transcript.url.path)
            // Nothing written for a long while: stuck or gone, not working.
            guard now.timeIntervalSince(transcript.date) < 15 * 60 else { continue }
            let tail = read(transcript.url, tail: true)
            guard ClaudeTranscript.isMidTurn(tail) else { continue }
            found.append(Found(sessionID: transcript.url.deletingPathExtension().lastPathComponent, cwd: cwd,
                               hostPath: ProcessTree.hostApp(of: pid)?.bundlePath, tty: ProcessTree.terminal(of: pid),
                               title: ThreadTitle.named(inTail: tail) ?? ThreadTitle.fromTranscript(read(transcript.url, tail: false)), updated: transcript.date))
        }
        return found
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    static func read(_ url: URL, tail: Bool) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        let length: UInt64 = 256 * 1024
        if tail, let end = try? handle.seekToEnd(), end > length { try? handle.seek(toOffset: end - length) }
        return (try? handle.read(upToCount: Int(length))) ?? Data()
    }

    /// Every terminal some process still has open: `/dev/ttys003`. A thread whose tty isn't
    /// among them had its window closed.
    public static func liveTerminals() -> Set<String> {
        Set(allProcesses().compactMap(ProcessTree.ownTerminal))
    }

    static func allProcesses() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(max(Int(count), 0)))
    }

    static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    static func startDate(_ pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    /// The process's arguments, without the program itself.
    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        // argc, the executable's path, padding, then argv, all ending in zeros.
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        let strings = buffer[4..<size].split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        return Array(strings.dropFirst(2).prefix(max(Int(argc) - 1, 0)))
    }
}

/// Claude Code's transcripts: one JSON object per line in `~/.claude/projects/<folder>/<session>.jsonl`.
public enum ClaudeTranscript {
    public static var projects: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Claude Code names a project's folder after its path, every other character a dash.
    public static func folderName(for cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// The session a `claude` process was started for, if its arguments say.
    public static func sessionID(in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            for flag in ["--session-id", "--resume", "-r"] {
                if argument == flag, index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") { return arguments[index + 1] }
                if argument.hasPrefix(flag + "=") { return String(argument.dropFirst(flag.count + 1)) }
            }
        }
        return nil
    }

    /// Whether the last turn is still going: a prompt or tool result waits for the model, or the
    /// model asked for a tool. A turn ends on a reply that stopped by itself, or an interruption.
    public static func isMidTurn(_ tail: Data) -> Bool {
        for line in tail.split(separator: 0x0A).reversed() {
            // The first line of a tail can be cut off; it doesn't parse and is skipped.
            guard let entry = JSONValue.parse(Data(line)), let type = entry["type"]?.string, type == "user" || type == "assistant" else { continue }
            let message = entry["message"]
            if type == "assistant" {
                let reason = message?["stop_reason"]?.string
                return reason == nil || reason == "tool_use" || reason == "pause_turn"
            }
            let content = message?["content"]
            let text = content?.string ?? content?.array?.compactMap { $0["text"]?.string }.first ?? ""
            return !text.hasPrefix("[Request interrupted")
        }
        return false
    }
}
