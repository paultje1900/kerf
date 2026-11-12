import AppKit
import SwiftUI

/// A borderless panel over the menu bar that never takes focus, except while a page needs typing.
final class IslandPanel: NSPanel {
    /// Set while the open island shows a text field or a question.
    var acceptsKeyboard = false
    var wantsKeyboard: () -> Bool = { false }
    var onCancel: (() -> Void)?

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        // Only where `NotchSpace` isn't there: on every desktop, not in a full-screen app's space.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        NotchSpace.keep(self)
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        NotchSpace.keep(self)
    }

    override var canBecomeKey: Bool { acceptsKeyboard || wantsKeyboard() }
    override var canBecomeMain: Bool { false }
    // Stay on top of the menu bar instead of being pushed below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
