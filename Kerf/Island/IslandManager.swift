import AppKit
import KerfKit

/// An island on the notched display, and a floating one on each other display if wanted.
final class IslandManager {
    /// The running manager, for modules that need to close an island.
    static weak var current: IslandManager?
    private var controllers: [CGDirectDisplayID: IslandController] = [:]
    private var screenObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var fullScreenObservers: [NSObjectProtocol] = []
    private var scanTask: Task<Void, Never>?
    private var occlusionObserver: NSObjectProtocol?
    private var lockObservers: [NSObjectProtocol] = []
    private var isLocked = false
    private var saverRuns = false
    /// The screen is locked or the screen saver runs: nobody sees the island.
    var isScreenCovered: Bool { isLocked || saverRuns }
    /// The frontmost app's menu titles from the last look.
    private var menuItems: [CGRect] = []

    var displayVisibility: [JSONValue] {
        controllers.map { id, controller in
            .object(["display": .number(Double(id)), "hiddenForFullScreen": .bool(controller.isHiddenForFullScreen),
                     "windowVisible": .bool(controller.panel.isVisible)])
        }
    }

    func start() {
        Self.current = self
        Preferences.register()
        Hub.shared.observe { [weak self] in self?.applyHub() }
        rebuild()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildIfDisplaysChanged() }
        }
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil,
                                                                   queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAudioPause() }
        }
        // The island's own space is above the screen saver, and nothing of it belongs on a locked screen.
        for name in [Self.locked, Self.unlocked, Self.saverStarted, Self.saverStopped] {
            lockObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenCoverChanged(name) }
            })
        }
        // Switching spaces or apps may enter or leave full screen; the space animation takes a moment.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            fullScreenObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkFullScreenSoon() }
            })
        }
    }

    private static let locked = "com.apple.screenIsLocked"
    private static let unlocked = "com.apple.screenIsUnlocked"
    private static let saverStarted = "com.apple.screensaver.didstart"
    private static let saverStopped = "com.apple.screensaver.didstop"

    private func screenCoverChanged(_ name: String) {
        switch name {
        case Self.locked: isLocked = true
        case Self.saverStarted: saverRuns = true
        case Self.saverStopped: saverRuns = false
        // Unlocked: the saver is gone too, also when its own word got lost.
        default: (isLocked, saverRuns) = (false, false)
        }
        controllers.values.forEach { $0.setHiddenForLock(isScreenCovered) }
    }

    /// The notch, and the other displays if wanted. Without any notch on screen (a Mac without
    /// one, or a closed MacBook), the floating island on the main display: agents must reach you.
    private var wantedScreens: [NSScreen] {
        let external = UserDefaults.standard.bool(forKey: Preferences.showOnExternalDisplays)
        let wanted = NSScreen.screens.filter { $0.notchSize != nil || external }
        if wanted.isEmpty, let main = NSScreen.screens.first { return [main] }
        return wanted
    }

    private func rebuildIfDisplaysChanged() {
        if Set(wantedScreens.map(\.displayID)) != Set(controllers.keys) { rebuild() }
    }

    private func rebuild() {
        controllers.values.forEach { $0.remove() }
        controllers = [:]
        for screen in wantedScreens {
            let controller = IslandController(screen: screen)
            controller.apply(Hub.shared)
            controller.setHiddenForLock(isScreenCovered)
            controller.show()
            controllers[screen.displayID] = controller
        }
        checkFullScreenSoon()
    }

    private func checkFullScreenSoon() {
        scanTask?.cancel()
        scanTask = Task {
            // Menus are there at once; full screen takes the space animation to settle.
            for (delay, menus) in [(0.15, true), (0.6, false), (1.2, true)] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let scan = await Task.detached(priority: .utility) { MenuBarScan(front: front, readMenus: menus) }.value
                guard !Task.isCancelled else { return }
                apply(scan, front: front)
            }
        }
    }

    /// Hide for actual full screen, not a maximized window below the menu bar.
    private func apply(_ scan: MenuBarScan, front: pid_t?) {
        if let items = scan.menuItems { menuItems = items }
        let windows = scan.windows.filter { $0.pid == front && $0.layer == 0 }
        for controller in controllers.values {
            let display = CGDisplayBounds(controller.screen.displayID)
            let dockShown = scan.dockFrames.contains { $0.intersects(display) }
            let fills = windows.contains { window in
                WindowVisibility.hidesIsland(window: window.bounds, display: display, notch: controller.screen.safeAreaInsets.top,
                                             isFullScreen: window.isFullScreen, dockShown: dockShown)
            }
            controller.setHiddenForFullScreen(fills)
            if let range = controller.screen.notchRange {
                let items = menuItems.filter { abs($0.minY - display.minY) < 2 } + scan.statusItems(on: display)
                controller.island.setMenuRoom(MenuBarRoom.sides(notchMinX: range.lowerBound, notchMaxX: range.upperBound, items: items))
            }
        }
        updateAudioPause()
    }

    /// Nobody sees the waveform while every island is hidden: an app full screen, a sleeping
    /// display, the lock screen. Then there's no tap at all.
    private func updateAudioPause() {
        AudioLevels.shared.setPaused(controllers.values.allSatisfy { !$0.panel.occlusionState.contains(.visible) })
    }

    private func applyHub() {
        controllers.values.forEach { $0.apply(Hub.shared) }
    }

    /// The island in the MacBook's notch; only without one, the island under the pointer.
    private var currentController: IslandController? {
        controllers.values.first { $0.screen.notchSize != nil }
            ?? controllers.values.first { $0.screen.frame.contains(NSEvent.mouseLocation) }
            ?? controllers.values.first
    }

    /// After the last agent question is answered, islands open on it close.
    func closeAgents() {
        controllers.values.filter { $0.island.mode == .expanded && $0.island.page == .agents }.forEach { $0.close() }
    }

    /// ⌥ Space opens the ask field; ⌥⇧ Space takes the selected text along. Without Ask, ⌥ Space
    /// opens the island and closes it again.
    func openAsk(sendingSelection: Bool) {
        guard let controller = currentController else { return }
        guard Feature.ask.isOn else {
            if controller.island.mode == .expanded { controller.close() } else { controller.open(keyboard: true) }
            return
        }
        if sendingSelection {
            // Read the selection before the island takes the keyboard.
            guard let text = SelectionReader.selectedText() else { return }
            AskModule.shared.attachSelection(text)
        } else if controller.island.mode == .expanded, controller.island.page == .ask {
            controller.close()
            return
        }
        controller.open(page: .ask, keyboard: true)
    }

    /// After dropping a file on "Ask Claude": the ask page, ready to type.
    func showAsk() {
        currentController?.open(page: .ask, keyboard: true)
    }

    func closeAll() {
        controllers.values.filter { $0.island.mode == .expanded }.forEach { $0.close() }
    }

    /// Open islands follow their page's height.
    func refit() {
        controllers.values.forEach { $0.island.refit() }
    }

    /// Closes the island, lets you pick an area, and opens again with the picture attached.
    func screenshotForAsk() {
        let controller = currentController
        closeAll()
        Screenshot.take(into: KerfPaths.support.appendingPathComponent("Ask", isDirectory: true)) { url in
            if let url { AskModule.shared.attach([url]) }
            controller?.open(page: .ask, keyboard: true)
        }
    }
}
