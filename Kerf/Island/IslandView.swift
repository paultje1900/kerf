import KerfKit
import SwiftUI

struct IslandRoot: View {
    let island: Island

    var body: some View {
        // One Animatable reader per axis: width and height run on separate springs.
        Animated(value: island.width) { width in
            Animated(value: island.height) { height in
                Animated(value: island.shift) { shift in
                    IslandBody(island: island, width: width, height: height, shift: shift)
                }
            }
        }
        .padding(.top, island.geometry.style == .floating ? IslandGeometry.floatingTop : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        // The island is always dark, whatever the Mac's appearance: white text in its fields.
        .environment(\.colorScheme, .dark)
        .background(SettingsOpenerHost())
    }
}

/// Hands its interpolated value to the content on every frame of an animation.
struct Animated<Content: View>: View, Animatable {
    var value: CGFloat
    @ViewBuilder var content: (CGFloat) -> Content

    var animatableData: CGFloat {
        get { value }
        set { value = newValue }
    }

    var body: some View { content(value) }
}

struct IslandBody: View {
    let island: Island
    let width: CGFloat
    let height: CGFloat
    /// The island's middle, right of the notch's.
    let shift: CGFloat

    var body: some View {
        let geometry = island.geometry
        let openHeight = island.size(of: .expanded).height
        let radius = geometry.cornerRadius(height: height, openHeight: openHeight)
        let openness = geometry.openness(height: height, openHeight: openHeight)
        let ears = geometry.ears(width: width, shift: shift)
        ZStack(alignment: .top) {
            IslandShape(style: geometry.style, radius: radius, leadingEar: ears.leading, trailingEar: ears.trailing)
                // Pure black, the hardware notch's own colour.
                .fill(Color(.sRGB, red: 0, green: 0, blue: 0))
                .frame(width: width + ears.leading + ears.trailing, height: max(height, 0))
                .offset(x: (ears.trailing - ears.leading) / 2)
                .shadow(color: .black.opacity(0.4 * openness), radius: 18 * openness, y: 6 * openness)
            content
                // Content stays where the notch is; the shape moves over it.
                .offset(x: -shift)
                .frame(width: width, height: max(height, 0), alignment: .top)
                .clipShape(IslandShape(style: geometry.style, radius: radius))
        }
        .contentShape(Rectangle())
        .onTapGesture { island.onTap?() }
        .offset(x: shift)
    }

    private var content: some View {
        let style = island.geometry.style
        return ZStack(alignment: .top) {
            CompactView(
                presentation: island.presentation,
                centerWidth: style.centerWidth,
                height: style.bandHeight,
                waitingCount: island.waitingCount,
                usage: island.fittingUsage
            )
            .modifier(IslandContentEffect(hidden: 1 - island.compactShown, blur: 8))
            // Their own layer: the rings stay while what's beside them comes and goes.
            if let usage = island.usage {
                UsageRings()
                    .frame(width: usage.width, height: style.bandHeight)
                    .offset(x: (usage.side == .right ? 1 : -1) * (style.centerWidth + usage.width) / 2)
                    .modifier(IslandContentEffect(hidden: 1 - island.usageShown, blur: 8))
                    .allowsHitTesting(false)
            }
            if island.expandedMounted {
                // Laid out at full size and uncovered by the growing shape: content never moves.
                ExpandedView(island: island)
                    .frame(width: width, height: max(height, 0), alignment: .top)
                    .modifier(IslandContentEffect(hidden: 1 - island.expandedShown, blur: 14))
                    .allowsHitTesting(island.mode == .expanded)
            }
        }
    }
}

struct ExpandedView: View {
    let island: Island

    var body: some View {
        VStack(spacing: 0) {
            TabBand(island: island)
                .frame(height: island.geometry.style.bandHeight)
            // The page at its own height; the island follows it and scrolls what doesn't fit.
            ScrollView(.vertical) {
                PageView(page: island.page)
                    .padding(.bottom, ui(12))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [page = island.page] height in
                        island.setContentHeight(height, for: page)
                    }
            }
            .scrollDisabled(!island.contentScrolls)
            .scrollIndicators(island.contentScrolls ? .visible : .never)
            // An answer being written stays in view.
            .defaultScrollAnchor(island.page == .ask ? .bottom : .top)
            .id(island.page)
            .frame(height: island.contentHeight, alignment: .top)
            .modifier(IslandContentEffect(hidden: 1 - island.pageShown, blur: 8))
        }
        .frame(width: Layout.openWidth, alignment: .top)
        .foregroundStyle(.white)
        .environment(island)
    }
}

/// A notch island hangs from the top edge: flat top with concave ears, continuous corners at the
/// bottom. A floating island is a rounded pill, like Apple's Mac island.
nonisolated struct IslandShape: Shape {
    var style: IslandStyle
    var radius: CGFloat
    /// The flare on each side; a side that stays behind the notch has none.
    var leadingEar: CGFloat = 0
    var trailingEar: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        guard case .notch = style else {
            return RoundedRectangle(cornerRadius: min(radius, rect.height / 2), style: .continuous).path(in: rect)
        }
        let body = CGRect(x: rect.minX + leadingEar, y: rect.minY, width: rect.width - leadingEar - trailingEar, height: rect.height)
        let r = min(radius, body.width / 2, body.height)
        var path = Path(UnevenRoundedRectangle(bottomLeadingRadius: r, bottomTrailingRadius: r, style: .continuous).path(in: body).cgPath)
        // Overlap the body by half a point so no seam shows.
        if leadingEar > 0.5 {
            let e = min(leadingEar, body.height)
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: body.minX + 0.5, y: rect.minY))
            path.addLine(to: CGPoint(x: body.minX + 0.5, y: rect.minY + e))
            path.addLine(to: CGPoint(x: body.minX, y: rect.minY + e))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: body.minX, y: rect.minY))
            path.closeSubpath()
        }
        if trailingEar > 0.5 {
            let e = min(trailingEar, body.height)
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: body.maxX, y: rect.minY + e), control: CGPoint(x: body.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: body.maxX - 0.5, y: rect.minY + e))
            path.addLine(to: CGPoint(x: body.maxX - 0.5, y: rect.minY))
            path.closeSubpath()
        }
        return path
    }
}

/// Blur and fade, in place: how content enters and leaves the island.
struct IslandContentEffect: ViewModifier {
    var hidden: Double
    var blur: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: blur * hidden)
            .opacity(1 - hidden)
    }
}
