import SwiftUI
import UniformTypeIdentifiers

/// The shelf: files to drag out again, AirDrop, share, show in Finder, and the clipboard history,
/// each while it's on. During a drag, the places to drop: keep, AirDrop, and ask Claude.
struct ShelfPage: View {
    @Bindable private var shelf = ShelfModule.shared

    var body: some View {
        if shelf.isDropping {
            DropZones().foregroundStyle(.white)
        } else {
            let clipboard = Feature.clipboard.isOn && (shelf.showsClipboard || !Feature.shelf.isOn)
            VStack(alignment: .leading, spacing: ui(8)) {
                if Feature.clipboard.isOn, Feature.shelf.isOn {
                    HStack(spacing: ui(6)) {
                        segment("Clipboard", on: shelf.showsClipboard) { shelf.showsClipboard = true }
                        segment("Files", on: !shelf.showsClipboard) { shelf.showsClipboard = false }
                        Spacer()
                    }
                    .padding(.horizontal, ui(20))
                }
                if clipboard {
                    ClipboardList().padding(.horizontal, ui(20))
                } else {
                    files
                }
            }
            .foregroundStyle(.white)
            .padding(.top, ui(6))
            .onChange(of: shelf.showsClipboard) { IslandManager.current?.refit() }
        }
    }

    private func segment(_ title: LocalizedStringKey, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.page(12, weight: .semibold))
                .padding(.horizontal, ui(11)).frame(height: ui(26))
                .background(.white.opacity(on ? 0.22 : 0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var files: some View {
        Group {
            if shelf.items.isEmpty {
                VStack(spacing: ui(6)) {
                    Image(systemName: "tray").font(.page(22, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                    Text("Drop files on the notch").font(.page(14, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                    Text("They stay here for 24 hours.").font(.page(12)).foregroundStyle(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity, minHeight: ui(110))
            } else {
                VStack(alignment: .leading, spacing: ui(10)) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: ui(12)) {
                            ForEach(shelf.items) { ShelfTile(item: $0) }
                        }
                    }
                    HStack(spacing: ui(10)) {
                        IslandButton(title: "AirDrop") { shelf.airDrop(shelf.items.map(\.url)) }
                        ShareLink(items: shelf.items.map(\.url)) {
                            Text("Share")
                                .font(.page(15, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: ui(36))
                                .background(Color(white: 0.302), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        IslandButton(title: "Show in Finder") { shelf.showInFinder(shelf.items.map(\.url)) }
                    }
                }
                .padding(.horizontal, ui(20))
            }
        }
    }

    static var contentHeight: CGFloat {
        let shelf = ShelfModule.shared
        if shelf.isDropping { return 120 }
        if Feature.clipboard.isOn, shelf.showsClipboard || !Feature.shelf.isOn {
            return 52 + CGFloat(min(max(ClipboardModule.shared.clips.count, 1), 5)) * 34
        }
        return shelf.items.isEmpty ? 130 : 168
    }
}

struct ShelfTile: View {
    let item: ShelfModule.Item

    var body: some View {
        VStack(spacing: ui(4)) {
            Group {
                if let thumbnail = ShelfModule.shared.thumbnails[item.url] {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable()
                }
            }
            .frame(width: ui(44), height: ui(44))
            Text(verbatim: item.name).font(.page(11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                .frame(width: ui(70))
        }
        .frame(width: ui(72))
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Show in Finder") { ShelfModule.shared.showInFinder([item.url]) }
            Button("AirDrop") { ShelfModule.shared.airDrop([item.url]) }
            Divider()
            Button("Remove from Shelf") { ShelfModule.shared.remove(item) }
        }
        .accessibilityLabel(Text(verbatim: item.name))
    }
}

/// Where a dragged file can go, each its own target.
struct DropZones: View {
    var body: some View {
        HStack(spacing: ui(10)) {
            zone(symbol: "tray.and.arrow.down.fill", title: "Keep") { ShelfModule.shared.add($0) }
            zone(symbol: "dot.radiowaves.left.and.right", title: "AirDrop") { ShelfModule.shared.airDrop($0) }
            if Feature.ask.isOn {
                zone(symbol: "sparkle", title: "Ask Claude") { urls in
                    AskModule.shared.attach(urls)
                    IslandManager.current?.showAsk()
                }
            }
        }
        .padding(.horizontal, ui(20))
        .padding(.top, ui(6))
    }

    private func zone(symbol: String, title: LocalizedStringKey, drop: @escaping ([URL]) -> Void) -> some View {
        DropZone(symbol: symbol, title: title, drop: drop)
    }
}

struct DropZone: View {
    let symbol: String
    let title: LocalizedStringKey
    let drop: ([URL]) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: ui(8)) {
            Image(systemName: symbol).font(.page(22, weight: .semibold))
            Text(title).font(.page(13, weight: .semibold))
        }
        .frame(maxWidth: .infinity, minHeight: ui(96))
        .background(.white.opacity(targeted ? 0.22 : 0.08), in: RoundedRectangle(cornerRadius: ui(16), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ui(16), style: .continuous)
                .strokeBorder(.white.opacity(targeted ? 0.6 : 0.2), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
        .scaleEffect(targeted ? 1.03 : 1)
        .animation(.spring(Motion.hover), value: targeted)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task {
                let urls = await NSItemProvider.fileURLs(from: providers)
                guard !urls.isEmpty else { return }
                ShelfModule.shared.isDropping = false
                drop(urls)
                Hub.shared.refresh()
            }
            return true
        }
    }
}
