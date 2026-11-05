import AppKit
import ApplicationServices

/// The volume and brightness keys, caught before macOS shows its own bar, so the notch shows
/// the level instead. Needs Accessibility; without it macOS keeps its bar.
final class MediaKeys {
    static let shared = MediaKeys()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }
    private var trustWatch: Timer?
    private var trustObserver: NSObjectProtocol?

    /// Starts now if allowed; otherwise asks (once per version at launch, every time it's switched
    /// on) and starts the moment macOS says yes.
    func startWhenTrusted(asking: Bool = false) {
        start()
        guard tap == nil, Feature.levels.isOn else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if asking || UserDefaults.standard.string(forKey: "hud.askedForTrust") != version {
            UserDefaults.standard.set(version, forKey: "hud.askedForTrust")
            SelectionReader.requestTrust()
        }
        guard trustWatch == nil else { return }
        trustObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.5))
                MediaKeys.shared.start()
            }
        }
        trustWatch = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in
                MediaKeys.shared.start()
                if MediaKeys.shared.isRunning { MediaKeys.shared.stopWatchingTrust() }
            }
        }
        trustWatch?.tolerance = 1
    }

    private func stopWatchingTrust() {
        trustWatch?.invalidate()
        trustWatch = nil
        if let trustObserver { DistributedNotificationCenter.default().removeObserver(trustObserver) }
        trustObserver = nil
    }

    func start() {
        guard tap == nil, Feature.levels.isOn, AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1) << 14 // NX_SYSDEFINED
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: mediaKeyCallback, userInfo: nil) else { return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        stopWatchingTrust()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        source = nil
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// macOS steps: 16 per full range, 64 with ⌥⇧.
    fileprivate func handle(key: Int, fine: Bool) {
        let step = fine ? 1.0 / 64 : 1.0 / 16
        switch key {
        case 0, 1: // sound up, down
            let level = min(max(SystemVolume.level + (key == 0 ? step : -step), 0), 1)
            SystemVolume.level = level
            Hub.shared.show(.volume, SystemVolume.isMuted ? 0 : level)
        case 7: // mute
            SystemVolume.isMuted.toggle()
            Hub.shared.show(.volume, SystemVolume.isMuted ? 0 : SystemVolume.level)
        case 2, 3: // brightness up, down
            guard let level = Brightness.level else { return }
            let new = min(max(level + (key == 2 ? step : -step), 0), 1)
            Brightness.level = new
            Hub.shared.show(.brightness, new)
        default:
            break
        }
    }

    /// The keys this class takes over; the rest pass through.
    nonisolated fileprivate static let handledKeys: Set<Int> = [0, 1, 2, 3, 7]
}

nonisolated private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { MediaKeys.shared.reenable() }
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == 14, let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }
    let data = nsEvent.data1
    let key = (data & 0xFFFF_0000) >> 16
    let isDown = ((data & 0xFF00) >> 8) == 0xA
    guard MediaKeys.handledKeys.contains(key) else { return Unmanaged.passUnretained(event) }
    // Only take the key over when Kerf can actually do what it asks.
    let canHandle = MainActor.assumeIsolated { key == 2 || key == 3 ? Brightness.level != nil : SystemVolume.isSettable }
    guard canHandle else { return Unmanaged.passUnretained(event) }
    if isDown {
        let fine = nsEvent.modifierFlags.contains(.option) && nsEvent.modifierFlags.contains(.shift)
        MainActor.assumeIsolated { MediaKeys.shared.handle(key: key, fine: fine) }
    }
    return nil
}

/// The built-in display's brightness, through Apple's DisplayServices.
enum Brightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let get: Get? = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: Get.self) }
    private static let set: Set? = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: Set.self) }

    private static var display: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }

    static var level: Double? {
        get {
            var value: Float = 0
            guard let get, get(display, &value) == 0 else { return nil }
            return Double(value)
        }
        set {
            guard let newValue, let set else { return }
            _ = set(display, Float(newValue))
        }
    }
}
