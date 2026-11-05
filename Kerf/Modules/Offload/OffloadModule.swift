import AppKit
import KerfKit
import SwiftUI

/// Camera cards: put one in, the notch offers to offload it. Uitladen → drive → project → copy
/// with checksums → done, with the folder one click away.
@Observable
final class OffloadModule {
    static let shared = OffloadModule()

    struct Drive: Identifiable, Equatable {
        let url: URL
        let name: String
        let free: Int64
        var id: String { url.path }
    }

    enum Step: Equatable {
        case card
        case drive
        case project(Drive)
        case copying
        case done
        case failed(String)
    }

    private(set) var card: CameraCard?
    private(set) var volume: URL?
    private(set) var step = Step.card
    private(set) var drives: [Drive] = []
    private(set) var projects: [String] = []
    private(set) var progress: OffloadCopier.Progress?
    private(set) var report: OffloadCopier.Report?
    @ObservationIgnored private var copier: OffloadCopier?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    static let lastDriveKey = "offload.lastDrive"
    static let templateKey = "offload.template"

    var template: OffloadTemplate {
        get {
            if let data = UserDefaults.standard.data(forKey: Self.templateKey), let saved = try? JSONDecoder().decode(OffloadTemplate.self, from: data) {
                return saved
            }
            return Locale.current.language.languageCode == .dutch ? .dutch : .english
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.templateKey) }
    }

    /// Shown while a card is in or a copy runs.
    var isActive: Bool { card != nil || step == .copying || step == .done }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { if let url { OffloadModule.shared.inspect(url) } }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { OffloadModule.shared.unmounted(url) }
        })
        // A card that was already in when Kerf started.
        for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsRemovableKey], options: [.skipHiddenVolumes]) ?? [] {
            inspect(url)
        }
    }

    /// Switched off: cards are no longer looked at. A copy that runs still finishes.
    func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        guard step != .copying else { return }
        card = nil
        volume = nil
        step = .card
        report = nil
        Hub.shared.refresh()
    }

    /// Only removable volumes are looked at; reading them happens off the main thread.
    private func inspect(_ url: URL) {
        let values = try? url.resourceValues(forKeys: [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey])
        guard values?.volumeIsRemovable == true || values?.volumeIsEjectable == true, step != .copying else { return }
        Task.detached(priority: .utility) {
            let found = CardScanner.scan(volume: url)
            await MainActor.run {
                guard let found, OffloadModule.shared.step != .copying else { return }
                OffloadModule.shared.found(found, on: url)
            }
        }
    }

    private func found(_ card: CameraCard, on volume: URL) {
        self.card = card
        self.volume = volume
        step = .card
        report = nil
        Sounds.play(.done)
        Hub.shared.refresh()
    }

    private func unmounted(_ url: URL?) {
        guard url?.standardizedFileURL == volume?.standardizedFileURL, step != .copying else { return }
        card = nil
        volume = nil
        if step != .done { step = .card }
        Hub.shared.refresh()
    }

    // MARK: Steps

    func chooseDrive() {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsReadOnlyKey, .volumeLocalizedNameKey, .volumeAvailableCapacityForImportantUsageKey, .volumeIsBrowsableKey]
        drives = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [])
            .filter { $0.standardizedFileURL != volume?.standardizedFileURL }
            .compactMap { url in
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsInternal != true, values.volumeIsReadOnly != true else { return nil }
                return Drive(url: url, name: values.volumeLocalizedName ?? url.lastPathComponent, free: values.volumeAvailableCapacityForImportantUsage ?? 0)
            }
        // The last one used first.
        if let last = UserDefaults.standard.string(forKey: Self.lastDriveKey), let index = drives.firstIndex(where: { $0.name == last }) {
            drives.insert(drives.remove(at: index), at: 0)
        }
        step = .drive
        Hub.shared.refresh()
    }

    func pick(_ drive: Drive) {
        UserDefaults.standard.set(drive.name, forKey: Self.lastDriveKey)
        projects = OffloadPlanner.projects(on: drive.url, template: template)
        step = .project(drive)
        Hub.shared.refresh()
    }

    func back() {
        switch step {
        case .project: step = .drive
        case .drive, .failed: step = .card
        default: break
        }
        Hub.shared.refresh()
    }

    func begin(project: String, on drive: Drive) {
        guard let card, let volume else { return }
        let template = template
        let plan = OffloadPlanner.plan(card: card, cardRoot: volume, drive: drive.url, project: project, template: template)
        let copier = OffloadCopier()
        self.copier = copier
        step = .copying
        progress = nil
        Hub.shared.refresh()
        Task.detached(priority: .userInitiated) {
            let throttle = Throttle(interval: 0.2)
            let outcome = copier.run(plan, template: template) { progress in
                // A few updates a second is plenty for the island.
                guard throttle.ready() || progress.filesDone == progress.filesTotal else { return }
                Task { @MainActor in OffloadModule.shared.update(progress) }
            }
            await MainActor.run { OffloadModule.shared.finish(outcome) }
        }
    }

    func cancel() {
        copier?.cancel()
    }

    private func update(_ progress: OffloadCopier.Progress) {
        guard step == .copying else { return }
        self.progress = progress
        Hub.shared.refresh()
    }

    private func finish(_ outcome: OffloadCopier.Outcome) {
        copier = nil
        switch outcome {
        case .finished(let report):
            self.report = report
            step = .done
            Sounds.play(.done)
            Hub.shared.flash(.banner(.symbol("sdcard.fill", .white),
                                     report.mismatches.isEmpty ? .symbol("checkmark.circle.fill", Color(nsColor: .systemGreen)) : .symbol("exclamationmark.triangle.fill", Color(nsColor: .systemOrange))),
                             seconds: 3)
        case .cancelled:
            step = .card
        case .failed(let message):
            step = .failed(message)
        }
        progress = nil
        Hub.shared.refresh()
    }

    func showInFinder() {
        guard let folder = report?.cardFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// Not now: the card stays in, the notch lets it be until it comes back.
    func dismissCard() {
        card = nil
        Hub.shared.refresh()
    }

    func dismiss() {
        report = nil
        step = .card
        if volume == nil { card = nil }
        Hub.shared.refresh()
    }

    var compactPresentation: CompactPresentation? {
        if step == .copying { return .offload(progress?.fraction ?? 0) }
        guard let card, step != .done else { return nil }
        return .card(card.name)
    }

    /// Lab only.
    func preview(card: CameraCard?, step: Step, progress: OffloadCopier.Progress? = nil, report: OffloadCopier.Report? = nil,
                 drives: [Drive] = [], projects: [String] = []) {
        self.card = card
        volume = card == nil ? nil : URL(fileURLWithPath: "/Volumes/Untitled")
        self.step = step
        self.progress = progress
        self.report = report
        self.drives = drives
        self.projects = projects
        Hub.shared.refresh()
    }
}

/// Lets something through at most once per interval, from any thread.
nonisolated final class Throttle: @unchecked Sendable {
    private let interval: TimeInterval
    private let lock = NSLock()
    private var last = Date.distantPast

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func ready() -> Bool {
        lock.withLock {
            guard Date().timeIntervalSince(last) >= interval else { return false }
            last = Date()
            return true
        }
    }
}
