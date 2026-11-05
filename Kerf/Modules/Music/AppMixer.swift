import AppKit
import AudioToolbox
import CoreAudio
import Synchronization

/// A volume per app, which macOS itself can't do. An app below 100 % gets a Core Audio tap that
/// mutes its own output while Kerf reads it, and Kerf plays it again at the chosen level.
/// At 100 % the tap goes away and the app plays untouched.
@Observable
final class AppMixer {
    static let shared = AppMixer()

    struct Channel: Identifiable, Equatable {
        let id: String
        let name: String
        let icon: NSImage?
        let processes: [AudioObjectID]
        let isPlaying: Bool
        var gain: Double

        static func == (a: Channel, b: Channel) -> Bool {
            a.id == b.id && a.processes == b.processes && a.isPlaying == b.isPlaying && a.gain == b.gain
        }
    }

    private(set) var channels: [Channel] = []
    @ObservationIgnored private var taps: [String: GainTap] = [:]
    @ObservationIgnored private var started = false
    private static let gainsKey = "mixer.gains"

    private var gains: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: Self.gainsKey) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.gainsKey) }
    }

    /// Follows apps starting and stopping sound, and the output changing (AirPods in, out).
    func start() {
        guard !started else { return }
        started = true
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
                MainActor.assumeIsolated {
                    if selector == kAudioHardwarePropertyDefaultOutputDevice { AppMixer.shared.rebuildTaps() }
                    AppMixer.shared.refresh()
                }
            }
        }
        refresh()
    }

    /// Every open app that uses sound, playing or not. Helpers count as their app,
    /// so Safari's WebKit and Chrome's helpers show as Safari and Chrome.
    func refresh() {
        guard Feature.mixer.isOn else { return }
        let own = getpid()
        var grouped: [String: (name: String, icon: NSImage?, processes: [AudioObjectID], playing: Bool)] = [:]
        for process in AudioProcess.all() where process.pid != own {
            let owner = AudioProcess.responsibleApp(for: process.pid)
            // Real apps only, not system helpers like the simulator's audio process.
            guard let owner, owner.activationPolicy == .regular, let bundleID = owner.bundleIdentifier else { continue }
            // Some apps carry invisible direction marks in their name (WhatsApp does).
            let name = (owner.localizedName ?? bundleID).filter { !"\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}".contains($0) }
            var entry = grouped[bundleID] ?? (name, owner.icon, [], false)
            entry.processes.append(process.object)
            entry.playing = entry.playing || process.isPlaying
            grouped[bundleID] = entry
        }
        let gains = gains
        let found = grouped
            .map { Channel(id: $0.key, name: $0.value.name, icon: $0.value.icon, processes: $0.value.processes, isPlaying: $0.value.playing,
                           gain: gains[$0.key] ?? 1) }
            .sorted { ($0.isPlaying ? 0 : 1, $0.name) < ($1.isPlaying ? 0 : 1, $1.name) }
        // The open page asks every 1.5 s: only redraw when something changed.
        if found != channels { channels = found }
        applyTaps()
    }

    func setGain(_ gain: Double, for channel: Channel) {
        var gains = gains
        gains[channel.id] = gain > 0.99 ? nil : gain
        self.gains = gains
        if let index = channels.firstIndex(where: { $0.id == channel.id }) { channels[index].gain = gain }
        if let tap = taps[channel.id] { tap.gain = Float(gain) }
        applyTaps()
    }

    /// A tap for each app below 100 % that has processes; none for the rest.
    private func applyTaps() {
        for channel in channels {
            let wants = tapsAllowed && channel.gain < 0.99 && !channel.processes.isEmpty
            if wants, taps[channel.id]?.processes != channel.processes {
                taps[channel.id]?.stop()
                let tap = GainTap(processes: channel.processes, gain: Float(channel.gain))
                do {
                    try tap.start()
                    taps[channel.id] = tap
                } catch {
                    tap.stop()
                    taps[channel.id] = nil
                }
            } else if !wants, let tap = taps[channel.id] {
                tap.stop()
                taps[channel.id] = nil
            }
        }
        for id in taps.keys where !channels.contains(where: { $0.id == id }) {
            taps[id]?.stop()
            taps[id] = nil
        }
    }

    private func rebuildTaps() {
        taps.values.forEach { $0.stop() }
        taps = [:]
    }

    func stopAll() {
        rebuildTaps()
    }

    /// Switched off: every app plays at its own volume again.
    func switchOff() {
        stopAll()
        channels = []
    }

    /// Off in the lab, like the level tap.
    var tapsAllowed = true
}

nonisolated struct AudioProcess {
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isPlaying: Bool

    static func all() -> [AudioProcess] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.map { object in
            AudioProcess(object: object, pid: value(object, kAudioProcessPropertyPID, default: pid_t(-1)),
                         bundleID: string(object, kAudioProcessPropertyBundleID),
                         isPlaying: value(object, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0)
        }
    }

    private static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default fallback: T) -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var result = fallback
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr ? result : fallback
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr, let result else { return nil }
        let string = result.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    private typealias Responsible = @convention(c) (pid_t) -> pid_t
    private static let responsible: Responsible? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: Responsible.self) }

    /// The audio processes playing for an app, its helpers included; all of them if none plays.
    static func objects(playingFor app: pid_t) -> [AudioObjectID] {
        let owned = all().filter { $0.pid == app || responsible?($0.pid) == app }
        let playing = owned.filter(\.isPlaying)
        return (playing.isEmpty ? owned : playing).map(\.object)
    }

    /// The app a helper process plays for: Safari for WebKit, Chrome for its helpers.
    static func responsibleApp(for pid: pid_t) -> NSRunningApplication? {
        let owner = responsible?(pid) ?? pid
        return NSRunningApplication(processIdentifier: owner > 0 ? owner : pid) ?? NSRunningApplication(processIdentifier: pid)
    }
}

/// One app's sound, muted at the source and played again at `gain`.
nonisolated final class GainTap: @unchecked Sendable {
    let processes: [AudioObjectID]
    private let level: Atomic<UInt32>
    private let queue = DispatchQueue(label: "nl.paulboerma.kerf.mixer", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    var gain: Float {
        get { Float(bitPattern: level.load(ordering: .relaxed)) }
        set { level.store(newValue.bitPattern, ordering: .relaxed) }
    }

    init(processes: [AudioObjectID], gain: Float) {
        self.processes = processes
        level = Atomic(gain.bitPattern)
    }

    func start() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        // Silent at the source only while Kerf reads it: if Kerf stops, the app sounds normal again.
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        description.name = "Kerf mixer"
        try check(AudioHardwareCreateProcessTap(description, &tapID))
        let output = try TapEngine.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Kerf Mixer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            // Same clock as the output it plays to: resampling would only cost the audio daemon.
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: false, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, output, _ in
            self?.render(input, into: output)
        })
        try check(AudioDeviceStart(aggregateID, procID))
    }

    /// The tap's stereo in, scaled, onto every output channel (left and right repeat on more).
    private func render(_ input: UnsafePointer<AudioBufferList>, into output: UnsafeMutablePointer<AudioBufferList>) {
        let gain = gain
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        guard let source = inputs.first, let samples = source.mData?.assumingMemoryBound(to: Float.self) else {
            for buffer in outputs { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
            return
        }
        let sourceChannels = max(Int(source.mNumberChannels), 1)
        let frames = Int(source.mDataByteSize) / MemoryLayout<Float>.size / sourceChannels
        var channelOffset = 0
        for buffer in outputs {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let outputFrames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            for frame in 0..<outputFrames {
                for channel in 0..<channels {
                    data[frame * channels + channel] = frame < frames
                        ? samples[frame * sourceChannels + (channelOffset + channel) % sourceChannels] * gain
                        : 0
                }
            }
            channelOffset += channels
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw TapEngine.Failure.status(status) }
    }
}
