import AppKit
import KerfKit
import SwiftUI

/// One island on one screen: its panel, hovering, opening and closing.
final class IslandController {
    let island: Island
    let panel: IslandPanel
    let screen: NSScreen
    private var monitors: [Any] = []
    private var hoverTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    /// Only used when "close when the pointer leaves" is on: opened on purpose (a click, ⌥ Space,
    /// a click inside) still stays.
    private(set) var pinned = false

    /// Big enough for the open island at its tallest, and its shadow.
    static let panelSize = CGSize(width: Layout.openWidth + 140, height: 32 + Layout.tallContentHeight + 60)

    init(screen: NSScreen, interactive: Bool = true) {
        self.screen = screen
        island = Island(style: screen.islandStyle)
        let size = Self.panelSize
        let frame = screen.frame
        panel = IslandPanel(frame: NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height))
        let host = ClickThroughHostingView(rootView: IslandRoot(island: island))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        // Always dark, like the island itself: text fields get white text.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.ignoresMouseEvents = true
        panel.onCancel = { [weak self] in self?.close() }
        panel.wantsKeyboard = { [weak self] in
            guard let island = self?.island else { return false }
            // Open, a click in a text field may take the keyboard; hovering never does.
            return island.mode == .expanded
        }
        island.onTap = { [weak self] in
            guard let self, island.mode != .expanded else { return }
            // A thread's notice goes straight to its chat, like tapping a notification.
            if AgentCenter.shared.requests.isEmpty, !Hub.shared.agentWaiting,
               case .agentNotice = Hub.shared.presentation, let newest = AgentCenter.shared.notices.first {
                hoverTask?.cancel()
                hoverTask = nil
                AgentCenter.shared.open(newest)
                return
            }
            open(pinned: true)
        }
        island.onClose = { [weak self] in self?.close() }
        if interactive { watchPointer() }
    }

    /// Hidden while an app is full screen on this display.
    private(set) var isHiddenForFullScreen = false

    func show() {
        guard !isHiddenForFullScreen else { return }
        panel.orderFrontRegardless()
    }

    func setHiddenForFullScreen(_ hidden: Bool) {
        guard hidden != isHiddenForFullScreen else { return }
        isHiddenForFullScreen = hidden
        if hidden {
            if island.mode == .expanded { close() }
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func remove() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel.orderOut(nil)
    }

    /// Follows the hub: compact content, the agent dot, the page list.
    func apply(_ hub: Hub) {
        if island.pages != hub.pages { island.pages = hub.pages }
        let available = hub.pages + hub.morePages
        if !available.contains(island.page), let start = hub.startPage { island.select(start) }
        island.show(hub.presentation, waiting: hub.waitingCount)
        // The open page may need another height now.
        island.refit()
    }

    func open(page: IslandPage? = nil, keyboard: Bool = false, pinned: Bool = false) {
        hoverTask?.cancel()
        hoverTask = nil
        // A waiting agent or a thread's notice comes first; otherwise the overview (or, without it,
        // the threads), every time. Every page off and nothing waiting: nothing to open on.
        guard let target = page ?? Hub.shared.attentionPage ?? Hub.shared.startPage else { return }
        // Only the keyboard keeps it open after the pointer leaves: you are typing in it.
        self.pinned = self.pinned || keyboard
        if island.mode != .expanded { AgentCenter.shared.navigation.openOldest() }
        island.select(target)
        island.go(.expanded)
        panel.ignoresMouseEvents = false
        if keyboard {
            panel.acceptsKeyboard = true
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        closeTask?.cancel()
        closeTask = nil
        pinned = false
        ShelfModule.shared.showsClipboard = true
        island.go(island.restingMode)
        if panel.isKeyWindow || panel.acceptsKeyboard {
            panel.acceptsKeyboard = false
            // Hand the keyboard back to the app underneath.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    // MARK: Pointer

    private func watchPointer() {
        let moved: (NSEvent) -> Void = { [weak self] _ in self?.pointerMoved() }
        let kinds: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: moved) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { moved($0); return $0 }) { monitors.append(local) }
        // A drag over the notch that ends without a drop closes the drop places again.
        if let release = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            guard let self, ShelfModule.shared.isDropping, island.mode == .expanded else { return }
            Task {
                try? await Task.sleep(for: .seconds(0.3))
                guard ShelfModule.shared.isDropping else { return }
                ShelfModule.shared.isDropping = false
                self.close()
            }
        }) { monitors.append(release) }
        // Escape closes the open island from any app (needs Accessibility, which the HUD asks for).
        if let escape = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, event.keyCode == 53, island.mode == .expanded else { return }
            close()
        }) { monitors.append(escape) }
        // Scrolling over the island changes the volume.
        if let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            guard let self, event.window === panel, island.mode != .expanded, Feature.levels.isOn else { return event }
            let direction = event.isDirectionInvertedFromDevice ? -1.0 : 1.0
            let step = event.hasPreciseScrollingDeltas ? 0.004 : 0.04
            let level = min(max(SystemVolume.level + event.scrollingDeltaY * direction * step, 0), 1)
            SystemVolume.level = level
            Hub.shared.show(.volume, level)
            return nil
        }) { monitors.append(scroll) }
    }

    /// A text field in the island is being edited.
    private var isTyping: Bool {
        panel.isKeyWindow && panel.firstResponder is NSTextView
    }

    /// Whether the current drag carries files.
    private static var dragHasFiles: Bool {
        NSPasteboard(name: .drag).types?.contains(.fileURL) ?? false
    }

    /// The area that counts as "on the island", in screen coordinates.
    private var hotZone: NSRect {
        var size = island.size(of: island.mode)
        if island.mode == .idle, island.geometry.style == .floating { size = CGSize(width: 200, height: 8) }
        let top = screen.frame.maxY - (island.geometry.style == .floating ? IslandGeometry.floatingTop : 0)
        // Up to 12 pt of air on each side, less where an app's menus come close.
        let wings = max(0, (size.width - island.geometry.idle.width) / 2)
        let air = min(12, max(0, island.menuRoom - wings - 2))
        return NSRect(x: screen.frame.midX - size.width / 2 - air, y: top - size.height - 10, width: size.width + 2 * air, height: size.height + 10)
    }

    /// Hover lifts the island at once and opens it after resting there; away closes it.
    private func pointerMoved() {
        guard !isHiddenForFullScreen else { return }
        let inside = hotZone.contains(NSEvent.mouseLocation)
        // Only touch the window server when something changes; this runs on every mouse move.
        if !panel.acceptsKeyboard, panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if inside {
            closeTask?.cancel()
            closeTask = nil
            guard island.mode != .expanded else { return }
            island.setHovered(true)
            guard hoverTask == nil else { return }
            // Dragging files to the notch opens it almost at once, on the drop places.
            let dragging = Feature.shelf.isOn && NSEvent.pressedMouseButtons & 1 != 0 && Self.dragHasFiles
            let delay = dragging ? 0.15 : UserDefaults.standard.double(forKey: Preferences.hoverOpenDelay)
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                hoverTask = nil
                if dragging {
                    ShelfModule.shared.isDropping = true
                    open(page: .shelf)
                } else {
                    open()
                }
            }
        } else {
            hoverTask?.cancel()
            hoverTask = nil
            island.setHovered(false)
            // Leaving the notch makes the island small again, also after clicking in it. It stays
            // while you type in it, while a drag drops, or when you switched this off.
            guard island.mode == .expanded, closeTask == nil, !pinned, UserDefaults.standard.bool(forKey: Preferences.closesOnLeave),
                  !isTyping, !ShelfModule.shared.isDropping else { return }
            closeTask = Task {
                try? await Task.sleep(for: .seconds(0.4))
                guard !Task.isCancelled else { return }
                closeTask = nil
                ShelfModule.shared.isDropping = false
                close()
            }
        }
    }
}
