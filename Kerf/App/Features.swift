import Foundation
import KerfKit
import SwiftUI

/// What Kerf does, each switched on or off in Settings → Features. Out of the box Kerf is the
/// notch for coding agents: only Agents is on, the rest waits until you switch it on.
enum Feature: String, CaseIterable, Identifiable {
    case agents, usage, github, ask
    case music, mixer, levels
    case calendar, weather, timer
    case shelf, clipboard, downloads, offload
    case camera, charging, airpods, render

    var id: String { rawValue }

    var key: String { "feature.\(rawValue)" }

    var isOnByDefault: Bool { self == .agents }

    var isOn: Bool { FeatureSwitches.shared.isOn(self) }

    func set(_ on: Bool) { FeatureSwitches.shared.set(self, on: on) }

    enum Group: CaseIterable, Identifiable {
        case coding, sound, day, files, extras

        var id: Self { self }

        var title: LocalizedStringResource {
            switch self {
            case .coding: "Coding"
            case .sound: "Music and Sound"
            case .day: "Your Day"
            case .files: "Files"
            case .extras: "Extras"
            }
        }

        var features: [Feature] { Feature.allCases.filter { $0.group == self } }
    }

    var group: Group {
        switch self {
        case .agents, .usage, .github, .ask: .coding
        case .music, .mixer, .levels: .sound
        case .calendar, .weather, .timer: .day
        case .shelf, .clipboard, .downloads, .offload: .files
        case .camera, .charging, .airpods, .render: .extras
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .agents: "Coding agents"
        case .usage: "Claude usage"
        case .github: "GitHub"
        case .ask: "Ask Claude"
        case .music: "Now Playing"
        case .mixer: "Mixer"
        case .levels: "Volume and brightness"
        case .calendar: "Calendar"
        case .weather: "Weather"
        case .timer: "Timers"
        case .shelf: "Shelf"
        case .clipboard: "Clipboard history"
        case .downloads: "Downloads"
        case .offload: "Camera cards"
        case .camera: "Camera mirror"
        case .charging: "Charging"
        case .airpods: "AirPods"
        case .render: "DaVinci Resolve"
        }
    }

    var summary: LocalizedStringResource {
        switch self {
        case .agents: "Claude Code, Codex and Copilot ask for permission and answers in the notch. Connect them under Agents."
        case .usage: "Three rings beside the notch, always there: how much is used of your 5-hour session, your week and your week of Fable. Read from your own Claude Code."
        case .github: "Pull requests, checks, issues and branches through the GitHub CLI (gh). Your pull requests also show beside the threads."
        case .ask: "⌥ Space asks Claude through your own Claude Code, ⌥⇧ Space asks about the selected text."
        case .music: "Whatever plays, with a live waveform in the notch."
        case .mixer: "A volume for every app that plays."
        case .levels: "Shown in the notch instead of macOS's own bar; scroll over the notch for volume. Needs Accessibility."
        case .calendar: "Today's events on Today, with a join button for calls."
        case .weather: "Temperature and rain on Today, from Open-Meteo for your approximate location."
        case .timer: "Countdowns in the notch."
        case .shelf: "Drop files on the notch: they stay 24 hours, ready to drag out, AirDrop or share."
        case .clipboard: "What you copied, ready to copy again."
        case .downloads: "Browser downloads and their progress."
        case .offload: "Copy a camera card into a project, every file checked."
        case .camera: "A quick look at yourself before a call."
        case .charging: "The battery level when you plug in."
        case .airpods: "Headphones and their battery when they connect. Needs Bluetooth."
        case .render: "Render progress from Resolve. Needs Preferences → General → External scripting using: Local."
        }
    }

    /// Starts what the feature watches. Also asks for the permission it needs, when switched on.
    fileprivate func start(asking: Bool) {
        switch self {
        case .agents: AgentCenter.shared.start()
        case .usage: ClaudeUsageModule.shared.start()
        case .github: GitHubModule.shared.start()
        case .ask:
            AskModule.shared.start()
            Shortcuts.update()
        case .music: NowPlayingModule.shared.start()
        case .mixer: AppMixer.shared.start()
        case .levels:
            MediaKeys.shared.startWhenTrusted(asking: asking)
        case .calendar:
            CalendarModule.shared.start()
            if asking, !CalendarModule.shared.hasAccess { CalendarModule.shared.requestAccess() }
        case .weather:
            WeatherModule.shared.start()
            if asking, !WeatherModule.shared.isAllowed { WeatherModule.shared.requestAccess() }
        case .timer, .camera: break
        case .shelf: ShelfModule.shared.start()
        case .clipboard: ClipboardModule.shared.start()
        case .downloads: DownloadsWatcher.shared.start()
        case .offload: OffloadModule.shared.start()
        case .charging: PowerWatcher.shared.start()
        case .airpods:
            if asking, !IOBluetoothWatcher.shared.isAllowed { IOBluetoothWatcher.shared.requestAccess() }
            IOBluetoothWatcher.shared.startIfAllowed()
        case .render: RenderWatcher.shared.start()
        }
    }

    fileprivate func stop() {
        switch self {
        case .agents: AgentCenter.shared.switchOff()
        case .usage: ClaudeUsageModule.shared.stop()
        case .github: GitHubModule.shared.stop()
        case .ask: Shortcuts.update()
        case .music: NowPlayingModule.shared.switchOff()
        case .mixer: AppMixer.shared.switchOff()
        case .levels: MediaKeys.shared.stop()
        case .calendar: CalendarModule.shared.stop()
        case .weather: WeatherModule.shared.stop()
        case .timer: TimerModule.shared.cancelAll()
        case .camera: break
        case .shelf: ShelfModule.shared.stop()
        case .clipboard: ClipboardModule.shared.stop()
        case .downloads: DownloadsWatcher.shared.stop()
        case .offload: OffloadModule.shared.stop()
        case .charging: PowerWatcher.shared.stop()
        case .airpods: IOBluetoothWatcher.shared.stop()
        case .render: RenderWatcher.shared.switchOff()
        }
    }
}

/// Which features are on, observed so Settings and the island follow a switch at once.
@Observable
final class FeatureSwitches {
    static let shared = FeatureSwitches()

    /// Lab runs show everything, whatever this Mac has switched on.
    var showsEverything = false
    private var on: Set<Feature>

    private init() {
        Self.keepWhatEarlierVersionsShowed()
        on = Set(Feature.allCases.filter { UserDefaults.standard.object(forKey: $0.key) as? Bool ?? $0.isOnByDefault })
    }

    /// Lab only: these features and no others, without touching the saved switches.
    func preview(only features: Set<Feature>) {
        showsEverything = false
        on = features
    }

    func isOn(_ feature: Feature) -> Bool {
        showsEverything || on.contains(feature)
    }

    func set(_ feature: Feature, on isOn: Bool) {
        UserDefaults.standard.set(isOn, forKey: feature.key)
        guard isOn != on.contains(feature) else { return }
        if isOn {
            on.insert(feature)
            feature.start(asking: true)
        } else {
            on.remove(feature)
            feature.stop()
        }
        Hub.shared.refresh()
    }

    /// At launch: only what's on starts, so a switched-off feature costs nothing.
    func startAll() {
        for feature in Feature.allCases where isOn(feature) { feature.start(asking: false) }
    }

    /// Before features could be switched off, Kerf showed everything. An update keeps that, so
    /// nothing disappears; a fresh install starts with only the agents.
    private static func keepWhatEarlierVersionsShowed() {
        let defaults = UserDefaults.standard
        let versionKey = "features.version"
        guard defaults.integer(forKey: versionKey) < 1 else { return }
        defaults.set(1, forKey: versionKey)
        let ranBefore = defaults.bool(forKey: Preferences.didRegisterLoginItem) || defaults.object(forKey: "hud.askedForTrust") != nil
            || FileManager.default.fileExists(atPath: KerfPaths.support.path)
        guard ranBefore else { return }
        for feature in Feature.allCases where defaults.object(forKey: feature.key) == nil {
            let on = switch feature {
            case .downloads: defaults.bool(forKey: "extras.downloads")
            case .airpods: defaults.object(forKey: "extras.airpods") as? Bool ?? true
            case .levels: defaults.object(forKey: "hud.replacesSystem") as? Bool ?? true
            // Newer than the switches: off until asked for.
            case .usage: false
            default: true
            }
            defaults.set(on, forKey: feature.key)
        }
    }
}
