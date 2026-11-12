import CoreGraphics

/// Where an island lives: hanging from a hardware notch, or floating just under the top edge of a
/// display without one, the way Apple's Mac island does.
public enum IslandStyle: Equatable, Sendable {
    case notch(CGSize)
    case floating

    /// The black space in the middle of the compact island: the notch itself, or the same room on
    /// a display without one, so both look alike.
    public var centerWidth: CGFloat {
        switch self {
        case .notch(let size): size.width
        case .floating: 120
        }
    }

    /// Height of the band at the top that the notch makes unusable in the middle.
    public var bandHeight: CGFloat {
        switch self {
        case .notch(let size): size.height
        case .floating: IslandGeometry.floatingCompactHeight
        }
    }
}

public enum IslandMode: Equatable, Sendable {
    case idle, compact, expanded
}

/// Island sizes in points.
public struct IslandGeometry: Equatable, Sendable {
    /// Room for compact content on each side of the notch.
    public static let wing: CGFloat = 40
    /// How much the island grows under the pointer before it opens.
    public static let hoverLift = CGSize(width: 10, height: 3)
    public static let floatingCompactHeight: CGFloat = 26
    /// A floating island keeps this gap to the top edge.
    public static let floatingTop: CGFloat = 4
    public static let notchRadius: CGFloat = 8
    public static let openRadius: CGFloat = 24
    /// The concave flare where a notch island meets the top edge.
    public static let ear: CGFloat = 6

    public var style: IslandStyle

    public init(style: IslandStyle) {
        self.style = style
    }

    /// A notch island hides behind the notch, 2 pt narrower and 1 pt shorter so no pixel shows
    /// around it. A floating island has no body at rest.
    public var idle: CGSize {
        switch style {
        case .notch(let notch): CGSize(width: notch.width - 2, height: notch.height - 1)
        case .floating: CGSize(width: 90, height: 0)
        }
    }

    public func compact(wings: CGFloat = wing) -> CGSize {
        CGSize(width: style.centerWidth + 2 * wings, height: style.bandHeight)
    }

    /// The compact island with content this wide on each side of the notch, and how far its
    /// middle sits right of the notch's. A side of a notch island without content stays behind
    /// the notch, like the idle island.
    public func compact(leading: CGFloat, trailing: CGFloat) -> (size: CGSize, shift: CGFloat) {
        let hidden: CGFloat = style == .floating ? 0 : -1
        let left = leading > 0 ? leading : hidden
        let right = trailing > 0 ? trailing : hidden
        return (CGSize(width: style.centerWidth + left + right, height: style.bandHeight), (right - left) / 2)
    }

    /// Bottom corner radius at a height: the notch's own radius when closed, growing to 24 pt open.
    /// A floating island is a capsule while it is compact.
    public func cornerRadius(height: CGFloat, openHeight: CGFloat) -> CGFloat {
        let closed = style == .floating ? IslandGeometry.floatingCompactHeight / 2 : IslandGeometry.notchRadius
        return closed + (IslandGeometry.openRadius - closed) * openness(height: height, openHeight: openHeight)
    }

    /// 0 at band height, 1 fully open.
    public func openness(height: CGFloat, openHeight: CGFloat) -> CGFloat {
        let band = style.bandHeight
        guard openHeight > band else { return 0 }
        return min(max((height - band) / (openHeight - band), 0), 1)
    }

    /// The flare at the top grows in as the island gets wider than the notch, so the idle island
    /// adds nothing around it. Floating islands have none.
    public func ear(width: CGFloat) -> CGFloat {
        ears(width: width, shift: 0).leading
    }

    /// The flare on each side, for an island whose middle sits `shift` right of the notch's: only
    /// where it reaches past the notch.
    public func ears(width: CGFloat, shift: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        guard case .notch(let notch) = style else { return (0, 0) }
        let reach = (width - notch.width) / 2
        return (min(IslandGeometry.ear, max(0, reach - shift)), min(IslandGeometry.ear, max(0, reach + shift)))
    }
}
