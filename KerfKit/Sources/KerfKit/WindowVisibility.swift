import CoreGraphics

public enum WindowVisibility {
    /// Whether a window of the app in front is full screen, so the island steps aside. Below a
    /// MacBook notch a maximized window has the same bounds as a full-screen one; Accessibility
    /// tells them apart. Without it the Dock and the menu bar do: a full-screen space shows
    /// neither, a maximized window leaves both (or just the menu bar, when the Dock hides itself).
    public static func hidesIsland(window: CGRect, display: CGRect, notch: CGFloat = 0, isFullScreen: Bool?,
                                   dockShown: Bool = true, menuBarShown: Bool = false) -> Bool {
        guard display.contains(CGPoint(x: window.midX, y: window.midY)) else { return false }
        if let isFullScreen { return isFullScreen }
        guard window.minX <= display.minX + 1, window.maxX >= display.maxX - 1, window.maxY >= display.maxY - 1 else { return false }
        // Over the menu bar too: full screen whatever the Dock does.
        if window.minY <= display.minY + 1 { return true }
        return !dockShown && !menuBarShown && window.minY <= display.minY + notch + 1
    }
}
