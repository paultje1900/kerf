import CoreGraphics

/// How much of the menu bar beside the notch is free. An app with many menus runs them right up
/// to the notch on both sides (macOS wraps them around it), and the island's wings must not
/// cover them.
public enum MenuBarRoom {
    public struct Sides: Equatable, Sendable {
        public var left: CGFloat
        public var right: CGFloat

        /// Until the menu bar is read, and on displays without a notch.
        public static let open = Sides(left: .infinity, right: .infinity)

        public init(left: CGFloat, right: CGFloat) {
            self.left = left
            self.right = right
        }
    }

    /// The free width on each side of the notch, in points. `items` are menu titles and status
    /// items in screen points; only x matters. Items behind the notch are hidden by the hardware,
    /// so they don't count.
    public static func sides(notchMinX: CGFloat, notchMaxX: CGFloat, items: [CGRect]) -> Sides {
        let middle = (notchMinX + notchMaxX) / 2
        let visible = items.filter { $0.maxX <= notchMinX || $0.minX >= notchMaxX }
        let left = visible.filter { $0.midX < middle }.map(\.maxX).max().map { notchMinX - $0 } ?? .infinity
        let right = visible.filter { $0.midX >= middle }.map(\.minX).min().map { $0 - notchMaxX } ?? .infinity
        return Sides(left: max(0, left), right: max(0, right))
    }

    /// The free width on the tighter side of the notch.
    public static func free(notchMinX: CGFloat, notchMaxX: CGFloat, items: [CGRect]) -> CGFloat {
        let sides = sides(notchMinX: notchMinX, notchMaxX: notchMaxX, items: items)
        return min(sides.left, sides.right)
    }

    /// Whether wings this wide fit: the concave ears and a hair of air come on top.
    public static func fits(wings: CGFloat, in room: CGFloat) -> Bool {
        wings + IslandGeometry.ear + 2 <= room
    }
}
