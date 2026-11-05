import AppKit
import CoreImage
import KerfKit
import SwiftUI

/// Whatever the system says is playing, through the MediaRemote adapter (bundled, run under
/// /usr/bin/perl). One Apple Music-style view for every source but a browser.
@Observable
final class NowPlayingModule {
    static let shared = NowPlayingModule()

    enum Command: Int {
        case play = 0, pause = 1, toggle = 2, next = 4, previous = 5
    }

    private(set) var state: NowPlayingState?
    private(set) var artwork: NSImage?
    /// The artwork's colour, bright enough for black: tints the waveform like Apple Music does.
    private(set) var tint = Color.pink
    private(set) var artworkKey = 0
    /// Paused music leaves the notch after two seconds (a design call over the iPhone's five
    /// minutes); the wait only rides out the gap between two tracks.
    private(set) var showsCompact = false
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var wakeObservers: [NSObjectProtocol] = []
    /// The bytes of the artwork on screen, and the track before this one: a new track that still
    /// carries its cover gets no artwork until its own arrives.
    @ObservationIgnored private var shownArtwork: Data?
    @ObservationIgnored private var previousTrack: NowPlayingState?
    @ObservationIgnored private var artworkCheck: Task<Void, Never>?
    @ObservationIgnored private var artworkCheckedTrack: String?
    /// Lab: a made-up track that the real one mustn't replace.
    @ObservationIgnored private var isPreview = false
    private(set) var lastUpdate: Date?

    private var adapter: (script: String, framework: String)? {
        guard let base = Bundle.main.resourceURL?.appendingPathComponent("MediaRemoteAdapter") else { return nil }
        let script = base.appendingPathComponent("mediaremote-adapter.pl").path
        guard FileManager.default.fileExists(atPath: script) else { return nil }
        return (script, base.appendingPathComponent("MediaRemoteAdapter.framework").path)
    }

    func start() {
        guard Feature.music.isOn else { return }
        if wakeObservers.isEmpty { watchWakes() }
        guard process == nil, let adapter else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [adapter.script, adapter.framework, "stream", "--no-diff", "--debounce=120"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.ended(status: status) }
        }
        do { try process.run() } catch { return }
        self.process = process
        let handle = pipe.fileHandleForReading
        Task.detached(priority: .utility) { [weak self] in
            var lastArtwork: Data?
            for try await line in handle.bytes.lines {
                let state = NowPlayingState.parseMusic(Data(line.utf8))
                var decoded: DecodedArtwork?
                if let data = state?.artwork, data != lastArtwork {
                    lastArtwork = data
                    decoded = DecodedArtwork(data)
                } else if state?.artwork == nil {
                    // The island may drop its artwork now (Spotify paused, YouTube on), so the
                    // same artwork coming back is new again.
                    lastArtwork = nil
                }
                await self?.receive(state, artwork: decoded)
            }
        }
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }

    /// Switched off: no adapter, no tap, nothing in the notch.
    func switchOff() {
        stop()
        hideTask?.cancel()
        artworkCheck?.cancel()
        state = nil
        artwork = nil
        shownArtwork = nil
        showsCompact = false
        AudioLevels.shared.stop()
        Hub.shared.refresh()
    }

    /// After sleep or a lock the stream can stop hearing about changes: start it fresh.
    func restart() {
        stop()
        failures = 0
        start()
    }

    private func watchWakes() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            wakeObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { NowPlayingModule.shared.restart() }
            })
        }
        wakeObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NowPlayingModule.shared.restart() }
        })
    }

    /// Asks once what plays, for when the music page opens.
    func refreshNow() {
        guard let adapter, !isPreview, Feature.music.isOn else { return }
        let asked = Date.now
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [adapter.script, adapter.framework, "get"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let state = NowPlayingState.parseMusic(data)
            let decoded = state?.artwork.flatMap(DecodedArtwork.init)
            await MainActor.run { NowPlayingModule.shared.receive(state, artwork: decoded, asked: asked) }
        }
    }

    private func ended(status: Int32) {
        process = nil
        failures += status == 0 ? 0 : 1
        guard failures < 4 else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            start()
        }
    }

    /// `asked`: when a one-off question went out. Its answer is dropped if the stream has spoken
    /// since, so an older snapshot can't put back the last track's cover.
    private func receive(_ new: NowPlayingState?, artwork decoded: DecodedArtwork?, asked: Date? = nil) {
        if let asked, let lastUpdate, lastUpdate > asked { return }
        // A line still underway when Now Playing was switched off.
        guard Feature.music.isOn else { return }
        failures = 0
        lastUpdate = .now
        let trackChanged = new?.track != state?.track
        if trackChanged { previousTrack = state }
        let stale = new?.hasStaleArtwork(after: previousTrack) ?? false
        if let data = new?.artwork, !stale {
            if data != shownArtwork, let decoded = decoded ?? DecodedArtwork(data) {
                artwork = NSImage(cgImage: decoded.image, size: NSSize(width: decoded.image.width, height: decoded.image.height))
                tint = decoded.tint
                shownArtwork = data
                artworkKey += 1
            }
        } else if (stale || trackChanged), artwork != nil {
            artwork = nil
            tint = .pink
            shownArtwork = nil
            artworkKey += 1
        }
        // The new cover may follow without a word from the stream: ask again a little later,
        // once per track.
        if let new, stale || trackChanged && new.artwork == nil, artworkCheckedTrack != new.track {
            artworkCheckedTrack = new.track
            checkArtworkSoon()
        }
        state = new
        AudioLevels.shared.follow(processID: new?.processID, playing: new?.isPlaying ?? false)
        updateCompact()
    }

    private func checkArtworkSoon() {
        artworkCheck?.cancel()
        artworkCheck = Task {
            for delay in [1.0, 3.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, state != nil, artwork == nil else { return }
                refreshNow()
            }
        }
    }

    private func updateCompact() {
        hideTask?.cancel()
        if state?.isPlaying == true {
            if !showsCompact { showsCompact = true }
        } else if showsCompact {
            hideTask = Task {
                try? await Task.sleep(for: .seconds(state == nil ? 0 : 2))
                guard !Task.isCancelled else { return }
                showsCompact = false
                Hub.shared.refresh()
            }
        }
        Hub.shared.refresh()
    }

    var compactPresentation: CompactPresentation? {
        guard showsCompact, state != nil else { return nil }
        return .nowPlaying(artworkKey: artworkKey, isPlaying: state?.isPlaying ?? false)
    }

    /// Lab only: a track without the adapter.
    func preview(_ state: NowPlayingState?, artwork: NSImage?, tint: Color) {
        stop()
        isPreview = true
        self.state = state
        self.artwork = artwork
        self.tint = tint
        artworkKey += 1
        updateCompact()
    }

    // MARK: Commands

    func send(_ command: Command) {
        // Answer at once; the stream confirms a moment later.
        if var state, command == .toggle || command == .play || command == .pause {
            state.elapsed = state.elapsed(at: .now)
            state.timestamp = .now
            state.isPlaying = command == .play || (command == .toggle && !state.isPlaying)
            self.state = state
            updateCompact()
        }
        run(["send", String(command.rawValue)])
    }

    func seek(to seconds: Double) {
        if var state {
            state.elapsed = seconds
            state.timestamp = .now
            self.state = state
        }
        run(["seek", String(Int(seconds * 1_000_000))])
    }

    func openSource() {
        guard let id = state?.sourceBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func run(_ arguments: [String]) {
        guard let adapter else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [adapter.script, adapter.framework] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

/// Artwork decoded and measured off the main thread.
nonisolated struct DecodedArtwork: Sendable {
    let image: CGImage
    let tint: Color

    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    init?(_ data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 256,
              ] as CFDictionary) else { return nil }
        self.image = image
        tint = Self.averageColour(image)
    }

    private static func averageColour(_ image: CGImage) -> Color {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent)]),
              let output = filter.outputImage else { return .pink }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        let colour = NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        // Bright and coloured enough to read on black.
        return Color(nsColor: NSColor(hue: colour.hueComponent, saturation: min(max(colour.saturationComponent, 0.45), 0.85),
                                      brightness: max(colour.brightnessComponent, 0.85), alpha: 1))
    }
}
