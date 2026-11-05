import AppKit
import SwiftUI

/// Downloads in Safari, Chrome and Firefox: progress in the compact island, a banner when done.
@Observable
final class DownloadsWatcher {
    static let shared = DownloadsWatcher()

    struct Active: Equatable {
        var name: String
        var fraction: Double?
    }

    private(set) var active: Active?
    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var inProgress: Set<String> = []

    private var folder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true) }

    /// Off until you switch it on in Settings, which is when macOS asks about the Downloads folder.
    func start() {
        guard source == nil, Feature.downloads.isOn else { return }
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { DownloadsWatcher.shared.scan() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        scan()
    }

    func stop() {
        source?.cancel()
        source = nil
        poll?.invalidate()
        poll = nil
        active = nil
        Hub.shared.refresh()
    }

    private static let partials = ["download", "crdownload", "part"]

    /// Looks at the folder's in-progress files; polls once a second only while something downloads.
    private func scan() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let partial = names.filter { Self.partials.contains(($0 as NSString).pathExtension.lowercased()) }
        let finished = inProgress.subtracting(partial)
        for name in finished {
            let final = (name as NSString).deletingPathExtension
            if names.contains(final) {
                Hub.shared.flash(.banner(.symbol("arrow.down.circle.fill", Color(nsColor: .systemBlue)), .symbol("checkmark", .white)), seconds: 3)
            }
        }
        inProgress = Set(partial)
        if let first = partial.first {
            active = Active(name: (first as NSString).deletingPathExtension, fraction: Self.safariFraction(folder.appendingPathComponent(first)))
            if poll == nil {
                poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    Task { @MainActor in DownloadsWatcher.shared.scan() }
                }
                poll?.tolerance = 0.3
            }
        } else {
            active = nil
            poll?.invalidate()
            poll = nil
        }
        Hub.shared.refresh()
    }

    /// Safari keeps its progress in the .download bundle's Info.plist.
    private static func safariFraction(_ bundle: URL) -> Double? {
        guard bundle.pathExtension == "download",
              let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Info.plist")),
              let done = info["DownloadEntryProgressBytesSoFar"] as? Double,
              let total = info["DownloadEntryProgressTotalToLoad"] as? Double, total > 0 else { return nil }
        return min(done / total, 1)
    }

    var compactPresentation: CompactPresentation? {
        active.map { .download($0.fraction) }
    }
}

/// DaVinci Resolve's render queue, read through Resolve's own scripting API while Resolve runs.
/// Needs Resolve → Preferences → General → External scripting: Local.
@Observable
final class RenderWatcher {
    static let shared = RenderWatcher()

    private(set) var percent: Double?
    private(set) var jobName: String?
    @ObservationIgnored private var helper: Process?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private static let resolveIDs = ["com.blackmagic-design.DaVinciResolve", "com.blackmagic-design.DaVinciResolveLite"]

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RenderWatcher.shared.update() }
            })
        }
        update()
    }

    func stop() {
        helper?.terminationHandler = nil
        helper?.terminate()
        helper = nil
    }

    /// Switched off: Resolve is no longer watched.
    func switchOff() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        stop()
        percent = nil
        jobName = nil
        Hub.shared.refresh()
    }

    private var resolveRuns: Bool {
        NSWorkspace.shared.runningApplications.contains { Self.resolveIDs.contains($0.bundleIdentifier ?? "") }
    }

    /// One quiet helper while Resolve is open. Starting Python for every look cost far more than
    /// the look itself.
    private func update() {
        if resolveRuns {
            startHelper()
        } else {
            stop()
            guard percent != nil else { return }
            percent = nil
            Hub.shared.refresh()
        }
    }

    /// Asks Resolve every few seconds and only prints when the answer changes. Stops by itself
    /// when Kerf is gone.
    nonisolated private static let script = """
    import json, os, sys, time
    sys.path.append("/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules")
    import DaVinciResolveScript as dvr
    resolve, last = None, None
    while os.getppid() != 1:
        out = {"rendering": False}
        try:
            resolve = resolve or dvr.scriptapp("Resolve")
            project = resolve.GetProjectManager().GetCurrentProject() if resolve else None
            if project and project.IsRenderingInProgress():
                for job in project.GetRenderJobList() or []:
                    status = project.GetRenderJobStatus(job["JobId"]) or {}
                    if status.get("JobStatus") == "Rendering":
                        out = {"rendering": True, "percent": status.get("CompletionPercentage", 0), "name": job.get("OutputFilename") or job.get("RenderJobName", "")}
        except Exception:
            resolve = None
        line = json.dumps(out)
        if line != last:
            print(line, flush=True)
            last = line
        time.sleep(3 if resolve else 10)
    """

    private func startHelper() {
        guard helper == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", Self.script]
        var environment = ProcessInfo.processInfo.environment
        environment["RESOLVE_SCRIPT_API"] = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"
        environment["RESOLVE_SCRIPT_LIB"] = "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            let id = finished.processIdentifier
            Task { @MainActor in RenderWatcher.shared.ended(id) }
        }
        guard (try? process.run()) != nil else { return }
        helper = process
        let handle = pipe.fileHandleForReading
        Task.detached(priority: .utility) {
            for try await line in handle.bytes.lines {
                guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                let percent = json["rendering"] as? Bool == true ? (json["percent"] as? Double ?? 0) / 100 : nil
                let name = json["name"] as? String
                await RenderWatcher.shared.receive(percent: percent, name: name)
            }
        }
    }

    private func ended(_ id: Int32) {
        guard helper?.processIdentifier == id else { return }
        helper = nil
    }

    private func receive(percent new: Double?, name: String?) {
        let wasRendering = percent != nil
        percent = new
        jobName = name
        if new == nil, wasRendering {
            Sounds.play(.done)
            Hub.shared.flash(.banner(.symbol("film.fill", .white), .symbol("checkmark.circle.fill", Color(nsColor: .systemGreen))), seconds: 4)
        }
        Hub.shared.refresh()
    }

    var compactPresentation: CompactPresentation? {
        percent.map { .render($0) }
    }
}
