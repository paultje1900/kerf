import AppKit

/// A window-server space of Kerf's own, one level above the desktops. Switching desktops slides
/// the old one away with everything on it, the menu bar and the windows that are on every desktop
/// included, so the island left the notch for a moment. In its own space it stays where it is.
/// It also stays above full-screen spaces and the screen saver, so the islands hide there themselves.
/// The calls are private: where one is missing, the island stays on the desktops as before.
enum NotchSpace {
    private typealias Connection = Int32
    private typealias Space = UInt64
    private typealias Create = @convention(c) (Connection, Int32, CFDictionary?) -> Space
    private typealias SetLevel = @convention(c) (Connection, Space, Int32) -> Void
    private typealias Spaces = @convention(c) (Connection, CFArray) -> Void
    private typealias Move = @convention(c) (Connection, Space, CFArray, Int32) -> Void
    private typealias Destroy = @convention(c) (Connection, Space) -> Void

    /// Above the desktops (0), below the login window's lock screen (300).
    private static let level: Int32 = 1
    private static let connection = function("CGSMainConnectionID", (@convention(c) () -> Connection).self)?()
    private static var space: Space? = {
        guard let connection, let create = function("CGSSpaceCreate", Create.self),
              let setLevel = function("CGSSpaceSetAbsoluteLevel", SetLevel.self), let show = function("CGSShowSpaces", Spaces.self),
              function("CGSSpaceAddWindowsAndRemoveFromSpaces", Move.self) != nil else { return nil }
        // 1: a plain space; with 0 the Finder draws its desktop icons in it.
        let space = create(connection, 1, nil)
        guard space != 0 else { return nil }
        setLevel(connection, space, level)
        show(connection, [space] as CFArray)
        return space
    }()

    /// Call after every order-front: a window that comes on screen lands on the desktops again.
    static func keep(_ window: NSWindow) {
        guard let connection, let space, window.windowNumber > 0,
              let move = function("CGSSpaceAddWindowsAndRemoveFromSpaces", Move.self) else { return }
        // 7: off every kind of space it's on.
        move(connection, space, [window.windowNumber] as CFArray, 7)
    }

    /// At quit, with everything else Kerf leaves with the system.
    static func remove() {
        guard let connection, let space else { return }
        function("CGSHideSpaces", Spaces.self)?(connection, [space] as CFArray)
        function("CGSSpaceDestroy", Destroy.self)?(connection, space)
        self.space = nil
    }

    private static func function<T>(_ name: String, _ type: T.Type) -> T? {
        // RTLD_DEFAULT
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }
    }
}
