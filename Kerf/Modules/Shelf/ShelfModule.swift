import AppKit
import KerfKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Files dropped on the notch, kept 24 hours in Kerf's own folder. Copies, never moves:
/// on the same disk that is an instant APFS clone.
@Observable
final class ShelfModule {
    static let shared = ShelfModule()

    struct Item: Identifiable, Equatable {
        let url: URL
        let added: Date
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    private(set) var items: [Item] = []
    private(set) var thumbnails: [URL: NSImage] = [:]
    /// The island opened for a drag: show where things can go.
    var isDropping = false
    /// The clipboard comes first; a drop shows the files until the island closes.
    var showsClipboard = true
    @ObservationIgnored private var timer: Timer?

    nonisolated static let lifetime: TimeInterval = 24 * 3600

    nonisolated static var folder: URL { KerfPaths.support.appendingPathComponent("Shelf", isDirectory: true) }

    func start() {
        guard timer == nil else { return }
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in ShelfModule.shared.reload() }
        }
        timer?.tolerance = 300
    }

    /// Switched off: the notch takes no more drops. What's kept stays in the folder until it's
    /// switched on again, which clears what's older than a day.
    func stop() {
        timer?.invalidate()
        timer = nil
        isDropping = false
    }

    /// Reads the folder, dropping what is older than a day.
    func reload() {
        Task.detached(priority: .utility) {
            let files = FileManager.default
            try? files.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            var kept: [Item] = []
            let drops = (try? files.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
            for drop in drops {
                let added = (try? drop.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
                if Date().timeIntervalSince(added) > Self.lifetime {
                    try? files.removeItem(at: drop)
                    continue
                }
                for file in (try? files.contentsOfDirectory(at: drop, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
                    kept.append(Item(url: file, added: added))
                }
            }
            let sorted = kept.sorted { $0.added > $1.added }
            await MainActor.run {
                ShelfModule.shared.items = sorted
                ShelfModule.shared.makeThumbnails()
                Hub.shared.refresh()
            }
        }
    }

    func add(_ urls: [URL]) {
        showsClipboard = false
        let files = urls
        Task.detached(priority: .userInitiated) {
            let drop = Self.folder.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6))", isDirectory: true)
            try? FileManager.default.createDirectory(at: drop, withIntermediateDirectories: true)
            for url in files {
                try? FileManager.default.copyItem(at: url, to: drop.appendingPathComponent(url.lastPathComponent))
            }
            await MainActor.run {
                ShelfModule.shared.reload()
                Hub.shared.flash(.banner(.symbol("tray.and.arrow.down.fill", .white), .symbol("checkmark", .white)), seconds: 1.5)
            }
        }
    }

    func remove(_ item: Item) {
        try? FileManager.default.removeItem(at: item.url)
        reload()
    }

    func clear() {
        try? FileManager.default.removeItem(at: Self.folder)
        reload()
    }

    func airDrop(_ urls: [URL]) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
    }

    func showInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func makeThumbnails() {
        for item in items where thumbnails[item.url] == nil {
            let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 96, height: 96), scale: 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                guard let image = representation?.cgImage else { return }
                let url = item.url
                Task { @MainActor in
                    ShelfModule.shared.thumbnails[url] = NSImage(cgImage: image, size: NSSize(width: 48, height: 48))
                }
            }
        }
    }

    /// Lab only.
    func preview(_ urls: [URL]) {
        items = urls.map { Item(url: $0, added: .now) }
        makeThumbnails()
        Hub.shared.refresh()
    }
}

extension NSItemProvider {
    /// File URLs from a drop, read without blocking.
    static func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await withCheckedContinuation({ (continuation: CheckedContinuation<URL?, Never>) in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
            }) {
                urls.append(url)
            }
        }
        return urls
    }
}
