import KerfKit
import SwiftUI

struct IslandRoot: View {
    let island: Island

    var body: some View {
        // One Animatable reader per axis: width and height run on separate springs.
        Animated(value: island.width) { width in
            Animated(value: island.height) { height in
                IslandBody(island: island, width: width, height: height)
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

    var body: some View {
        let geometry = island.geometry
        let openHeight = island.size(of: .expanded).height
        let radius = geometry.cornerRadius(height: height, openHeight: openHeight)
        let openness = geometry.openness(height: height, openHeight: openHeight)
        let ear = geometry.ear(width: width)
        ZStack(alignment: .top) {
            IslandShape(style: geometry.style, radius: radius, ear: ear)
                // Pure black, the hardware notch's own colour.
                .fill(Color(.sRGB, red: 0, green: 0, blue: 0))
                .frame(width: width + 2 * ear, height: max(height, 0))
                .shadow(color: .black.opacity(0.4 * openness), radius: 18 * openness, y: 6 * openness)
            content
                .frame(width: width, height: max(height, 0), alignment: .top)
                .clipShape(IslandShape(style: geometry.style, radius: radius, ear: 0))
        }
        .contentShape(Rectangle())
        .onTapGesture { island.onTap?() }
    }

    private var content: some View {
        ZStack(alignment: .top) {
            CompactView(
                presentation: island.presentation,
                centerWidth: island.geometry.style.centerWidth,
                height: island.geometry.style.bandHeight,
                waitingCount: island.waitingCount
            )
            .modifier(IslandContentEffect(hidden: 1 - island.compactShown, blur: 8))
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
    var ear: CGFloat

    func path(in rect: CGRect) -> Path {
        guard case .notch = style else {
            return RoundedRectangle(cornerRadius: min(radius, rect.height / 2), style: .continuous).path(in: rect)
        }
        let body = rect.insetBy(dx: ear, dy: 0)
        let r = min(radius, body.width / 2, body.height)
        var path = Path(UnevenRoundedRectangle(bottomLeadingRadius: r, bottomTrailingRadius: r, style: .continuous).path(in: body).cgPath)
        guard ear > 0.5 else { return path }
        let e = min(ear, body.height)
        // Overlap the body by half a point so no seam shows.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: body.minX + 0.5, y: rect.minY))
        path.addLine(to: CGPoint(x: body.minX + 0.5, y: rect.minY + e))
        path.addLine(to: CGPoint(x: body.minX, y: rect.minY + e))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: body.minX, y: rect.minY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: body.maxX, y: rect.minY + e), control: CGPoint(x: body.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: body.maxX - 0.5, y: rect.minY + e))
        path.addLine(to: CGPoint(x: body.maxX - 0.5, y: rect.minY))
        path.closeSubpath()
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
