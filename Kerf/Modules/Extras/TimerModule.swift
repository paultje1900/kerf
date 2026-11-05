import AppKit
import IOKit.ps
import KerfKit
import SwiftUI

/// Kitchen timers, as on iPhone: orange in the compact island, a sound and a banner when done.
@Observable
final class TimerModule {
    static let shared = TimerModule()

    struct Running: Identifiable, Equatable {
        let id = UUID()
        var end: Date
        let duration: TimeInterval
        /// Set while paused: what is left.
        var paused: TimeInterval?
    }

    private(set) var timers: [Running] = []
    @ObservationIgnored private var alarms: [UUID: Timer] = [:]

    static let presets: [TimeInterval] = [60, 180, 300, 600, 900, 1500, 2700, 3600]

    func start(_ duration: TimeInterval) {
        let timer = Running(end: .now.addingTimeInterval(duration), duration: duration)
        timers.append(timer)
        timers.sort { $0.end < $1.end }
        alarms[timer.id] = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            Task { @MainActor in TimerModule.shared.finished(timer.id) }
        }
        Hub.shared.refresh()
    }

    /// Switched off: every timer goes, without a sound.
    func cancelAll() {
        alarms.values.forEach { $0.invalidate() }
        alarms = [:]
        timers = []
        Hub.shared.refresh()
    }

    func pause(_ timer: Running) {
        guard let index = timers.firstIndex(where: { $0.id == timer.id }), timers[index].paused == nil else { return }
        timers[index].paused = max(timers[index].end.timeIntervalSinceNow, 0)
        alarms[timer.id]?.invalidate()
        alarms[timer.id] = nil
        Hub.shared.refresh()
    }

    func resume(_ timer: Running) {
        guard let index = timers.firstIndex(where: { $0.id == timer.id }), let left = timers[index].paused else { return }
        timers[index].paused = nil
        timers[index].end = .now.addingTimeInterval(left)
        let id = timer.id
        alarms[id] = Timer.scheduledTimer(withTimeInterval: left, repeats: false) { _ in
            Task { @MainActor in TimerModule.shared.finished(id) }
        }
        Hub.shared.refresh()
    }

    func cancel(_ timer: Running) {
        alarms[timer.id]?.invalidate()
        alarms[timer.id] = nil
        timers.removeAll { $0.id == timer.id }
        Hub.shared.refresh()
    }

    private func finished(_ id: UUID) {
        alarms[id] = nil
        timers.removeAll { $0.id == id }
        if UserDefaults.standard.bool(forKey: Preferences.playsSounds) { NSSound(named: "Glass")?.play() }
        Hub.shared.flash(.banner(.symbol("timer", Color(nsColor: .systemOrange)), .symbol("bell.fill", Color(nsColor: .systemOrange))), seconds: 6)
    }

    var compactPresentation: CompactPresentation? {
        timers.first.map { .timer(end: $0.end, paused: $0.paused) }
    }
}

/// Plugging in, the way iPhone shows it.
final class PowerWatcher: NSObject {
    static let shared = PowerWatcher()
    private var source: CFRunLoopSource?
    private var wasOnAC: Bool?

    func start() {
        guard source == nil else { return }
        wasOnAC = Self.onAC
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        if let source = IOPSNotificationCreateRunLoopSource(powerChanged, context)?.takeRetainedValue() {
            self.source = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
    }

    nonisolated static var onAC: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeRetainedValue() as String? else { return true }
        return type == kIOPSACPowerValue
    }

    nonisolated static var batteryPercent: Int? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let current = info[kIOPSCurrentCapacityKey] as? Int, let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return current * 100 / max
        }
        return nil
    }

    fileprivate func changed() {
        let onAC = Self.onAC
        defer { wasOnAC = onAC }
        guard onAC, wasOnAC == false, let percent = Self.batteryPercent else { return }
        Hub.shared.flash(.banner(.symbol("battery.100percent.bolt", Color(nsColor: .systemGreen)), .value("\(percent)%")), seconds: 2.5)
    }
}

nonisolated private func powerChanged(_ context: UnsafeMutableRawPointer?) {
    MainActor.assumeIsolated { PowerWatcher.shared.changed() }
}
