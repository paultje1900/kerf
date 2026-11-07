import KerfKit
import Synchronization
import SwiftUI

/// What the compact island shows, one thing on each side of the notch like the iPhone's leading
/// and trailing views. Modules add cases. Everything fits the same wings as the volume: the island
/// has two sizes, compact and open, and never grows for what it shows.
enum CompactPresentation: Equatable {
    /// A short message, one thing on each side. Transient.
    case banner(BannerSide, BannerSide)
    /// Artwork left, the waveform right.
    case nowPlaying(artworkKey: Int, isPlaying: Bool)
    /// Volume, brightness or keyboard light: symbol left, level right. Replaces the macOS HUD.
    case level(LevelKind, Double)
    /// An agent waits: its app's icon left, the orange dot (and how many wait) right.
    case agent(agent: AgentKind, hostPath: String?)
    /// Threads finished or asking in their own window: the newest's mark left, a tick (or a
    /// bubble) right, with how many when more than one. Stays until you click or look.
    case agentNotice(agent: AgentKind, hostPath: String?, count: Int, needsInput: Bool, failed: Bool)
    /// A camera card is in: card left, camera right.
    case card(String)
    /// A card is being copied: a ring left, the percentage right.
    case offload(Double)
    /// A timer: orange, counting down, as on iPhone.
    case timer(end: Date, paused: TimeInterval?)
    /// A browser download: arrow left, progress right.
    case download(Double?)
    /// DaVinci Resolve renders: film left, percentage right.
    case render(Double)
    /// Your PRs: a check failed, changes were asked or one got merged.
    case pullNotice(count: Int, tone: PullTone)

    /// Short-lived or urgent: shows even where it covers an app's menus.
    var showsOverMenus: Bool {
        switch self {
        case .banner, .level, .agent, .agentNotice: true
        default: false
        }
    }

    var noticeCount: Int {
        if case .agentNotice(_, _, let count, _, _) = self { count } else { 0 }
    }

    /// Same kind: update in place. Another kind: fade out, swap, fade in.
    var kind: String {
        switch self {
        case .banner(let leading, let trailing): "banner.\(leading.id).\(trailing.id)"
        case .nowPlaying: "nowPlaying"
        case .level(let kind, _): "level.\(kind)"
        case .agent: "agent"
        case .agentNotice: "agentNotice"
        case .card(let name): "card.\(name)"
        case .offload: "offload"
        case .timer: "timer"
        case .download: "download"
        case .render: "render"
        case .pullNotice: "pullNotice"
        }
    }
}

/// One side of a banner. Words don't fit beside the notch: a symbol, a few characters, or an
/// agent's mark.
enum BannerSide: Equatable {
    case symbol(String, Color)
    case value(String)
    case agent(AgentKind)

    var id: String {
        switch self {
        case .symbol(let name, _): name
        case .value(let text): text
        case .agent(let agent): agent.rawValue
        }
    }
}

struct BannerSideView: View {
    let side: BannerSide

    var body: some View {
        switch side {
        case .symbol(let name, let tint):
            Image(systemName: name).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
        case .value(let text):
            Text(verbatim: text).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.7)
        case .agent(let agent):
            AgentMark(agent: agent, hostPath: nil, size: 18)
        }
    }
}

struct CompactView: View {
    let presentation: CompactPresentation?
    let centerWidth: CGFloat
    let height: CGFloat
    private let wings = IslandGeometry.wing
    /// Threads waiting on you: the orange dot takes the right side, whatever else shows.
    let waitingCount: Int

    var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(width: wings)
            Color.clear.frame(width: centerWidth)
            Group {
                if waitingCount > 0 { AgentDot(count: waitingCount) } else { trailing }
            }
            .frame(width: wings)
        }
        .frame(height: height)
    }

    @ViewBuilder private var leading: some View {
        switch presentation {
        case .banner(let side, _):
            BannerSideView(side: side)
        case .nowPlaying:
            ArtworkView(image: NowPlayingModule.shared.artwork, size: 20, radius: 5)
        case .level(let kind, let value):
            Image(systemName: kind.symbol(value)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                .contentTransition(.symbolEffect(.replace))
        case .agent(let agent, let hostPath):
            AgentMark(agent: agent, hostPath: hostPath, size: 18)
        case .agentNotice(let agent, let hostPath, _, _, _):
            AgentMark(agent: agent, hostPath: hostPath, size: 18)
        case .card:
            Image(systemName: "sdcard.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
        case .offload(let value):
            ProgressRing(value: value)
        case .timer:
            Image(systemName: "timer").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(nsColor: .systemOrange))
        case .download:
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(nsColor: .systemBlue))
        case .render:
            Image(systemName: "film.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
        case .pullNotice:
            Image(systemName: "arrow.triangle.pull").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        switch presentation {
        case .banner(_, let side):
            BannerSideView(side: side)
        case .nowPlaying(_, let isPlaying):
            Waveform(tint: NowPlayingModule.shared.tint, isPlaying: isPlaying, size: 14)
        case .level(_, let value):
            LevelBar(value: value).frame(width: 26, height: 3)
        case .agent:
            AgentDot(count: waitingCount)
        case .agentNotice(_, _, let count, let needsInput, let failed):
            HStack(spacing: 3) {
                // A thread that stopped on an error outranks one that asks, which outranks one that's done.
                Image(systemName: failed ? "exclamationmark.triangle.fill" : needsInput ? "ellipsis.bubble.fill" : "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(nsColor: failed ? .systemRed : needsInput ? .systemOrange : .systemGreen))
                if count > 1 {
                    Text(verbatim: "\(count)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                        .contentTransition(.numericText())
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Threads to look at: \(count)"))
        case .card(let name):
            Image(systemName: "camera.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .accessibilityLabel(Text(verbatim: name))
        case .offload(let value):
            Text(verbatim: "\(Int(value * 100))%").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
        case .download(let fraction):
            if let fraction { ProgressRing(value: fraction) } else { ProgressView().controlSize(.mini).tint(.white) }
        case .render(let value):
            Text(verbatim: "\(Int(value * 100))%").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
        case .timer(let end, let paused):
            Group {
                if let paused {
                    Text(verbatim: Duration.seconds(paused).formatted(.time(pattern: paused >= 3600 ? .hourMinuteSecond : .minuteSecond)))
                        .opacity(0.6)
                } else {
                    Text(timerInterval: Date.now...max(end, .now), countsDown: true)
                }
            }
            .font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Color(nsColor: .systemOrange))
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(width: 38)
        case .pullNotice(let count, let tone):
            HStack(spacing: 3) {
                Image(systemName: tone.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(nsColor: tone.color))
                if count > 1 { Text(verbatim: "\(count)").font(.system(size: 11, weight: .semibold)) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Pull requests to look at: \(count)"))
        case nil:
            EmptyView()
        }
    }
}

/// Apple orange, with a soft glow. Stays until the thread moves on; with more than one thread
/// waiting, how many.
struct AgentDot: View {
    var count = 1
    var glows = true

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color(nsColor: .systemOrange))
                .frame(width: 9, height: 9)
                .shadow(color: Color(nsColor: .systemOrange).opacity(glows ? 0.8 : 0), radius: glows ? 4 : 0)
            if count > 1 {
                Text(verbatim: "\(count)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .contentTransition(.numericText())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count > 1 ? Text("\(count) threads are waiting for you") : Text("An agent is waiting for you"))
    }
}

enum LevelKind: String {
    case volume, brightness, keyboard

    func symbol(_ value: Double) -> String {
        switch self {
        case .volume:
            value <= 0 ? "speaker.slash.fill" : value < 0.34 ? "speaker.wave.1.fill" : value < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        case .brightness:
            value < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .keyboard:
            value <= 0 ? "light.min" : "light.max"
        }
    }
}

/// A thin white bar on a dim track, like the system's own level indicators.
struct LevelBar: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            Capsule().fill(.white.opacity(0.22))
                .overlay(alignment: .leading) {
                    Capsule().fill(.white).frame(width: proxy.size.width * min(max(value, 0), 1))
                }
        }
        .animation(.smooth(duration: 0.15), value: value)
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(white: 0.18)
                    Image(systemName: "music.note").font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Apple Music's waveform, tinted with the artwork's colour. Its bars follow the sound itself
/// once Kerf may listen; until then the SF Symbol moves.
struct Waveform: View {
    let tint: Color
    let isPlaying: Bool
    let size: CGFloat

    var body: some View {
        let levels = AudioLevels.shared
        if isPlaying, levels.isLive {
            LiveBars(tint: tint, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "waveform")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: isPlaying)
        }
    }
}

/// Six thin rounded bars around the middle, like Apple Music's island waveform. Plain Core
/// Animation layers that the audio thread moves itself: SwiftUI and the main thread never
/// redraw for them.
struct LiveBars: NSViewRepresentable {
    let tint: Color
    let height: CGFloat

    func makeNSView(context: Context) -> BarsView {
        BarsView(height: height)
    }

    func updateNSView(_ view: BarsView, context: Context) {
        view.setTint(NSColor(tint).cgColor)
    }

    static func dismantleNSView(_ view: BarsView, coordinator: ()) {
        view.detach()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BarsView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

final class BarsView: NSView {
    let layers: BarLayers
    private var tint: CGColor?
    private var occlusion: NSObjectProtocol?

    init(height: CGFloat) {
        layers = BarLayers(height: height)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(layers.container)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { layers.size }

    func setTint(_ color: CGColor) {
        guard color != tint else { return }
        tint = color
        layers.setTint(color)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        guard let window else { return }
        occlusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                                           queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        }
        AudioLevels.shared.board.add(layers)
        updateVisibility()
    }

    /// Hidden windows and sleeping displays get nothing drawn.
    private func updateVisibility() {
        let visible = window?.occlusionState.contains(.visible) == true
        layers.visible.store(visible, ordering: .relaxed)
        if visible { AudioLevels.shared.board.draw(AudioLevels.shared.levels) }
    }

    func detach() {
        layers.visible.store(false, ordering: .relaxed)
        AudioLevels.shared.board.remove(layers)
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
    }
}

/// The bar layers on screen, for the audio thread: it moves every set itself, in one transaction.
nonisolated final class BarBoard: Sendable {
    private let sets = Mutex<[ObjectIdentifier: BarLayers]>([:])

    func add(_ layers: BarLayers) {
        sets.withLock { $0[ObjectIdentifier(layers)] = layers }
    }

    func remove(_ layers: BarLayers) {
        sets.withLock { $0[ObjectIdentifier(layers)] = nil }
    }

    /// From any thread. Commits only when a bar moves by a pixel or more.
    func draw(_ levels: LevelMeter.Levels) {
        sets.withLock { sets in
            var began = false
            for layers in sets.values {
                guard let heights = layers.heights(for: levels) else { continue }
                if !began {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    began = true
                }
                layers.apply(heights)
            }
            if began { CATransaction.commit() }
        }
    }
}

/// Six rounded bars that only Kerf touches, so the audio thread may move them.
nonisolated final class BarLayers: @unchecked Sendable {
    let container = CALayer()
    /// False while the window is hidden or the display sleeps.
    let visible = Atomic<Bool>(false)
    private let bars: [CALayer]
    private let height: Float
    private let shortest: Float
    /// The heights on screen in half points; only touched under the board's lock.
    private var shown = LevelMeter.Levels(repeating: -1)
    let size: CGSize
    /// Lab only: how often the bars moved.
    nonisolated(unsafe) static var commits = 0

    init(height: CGFloat) {
        let width = max(1.5, height * 0.1)
        let gap = max(1.5, height * 0.11)
        self.height = Float(height)
        shortest = Float(height * 0.16)
        size = CGSize(width: CGFloat(LevelMeter.bars) * width + CGFloat(LevelMeter.bars - 1) * gap, height: height)
        bars = (0..<LevelMeter.bars).map { index in
            let bar = CALayer()
            // Core Animation looks the name up on every commit; a set one is found at once.
            bar.name = "bar"
            bar.cornerRadius = width / 2
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: height * 0.16)
            bar.position = CGPoint(x: CGFloat(index) * (width + gap) + width / 2, y: height / 2)
            return bar
        }
        bars.forEach(container.addSublayer)
    }

    func setTint(_ color: CGColor) {
        bars.forEach { $0.backgroundColor = color }
    }

    /// Nil when nothing would change on screen.
    func heights(for levels: LevelMeter.Levels) -> LevelMeter.Levels? {
        guard visible.load(ordering: .relaxed) else { return nil }
        let target = (pointwiseMax(levels * height, LevelMeter.Levels(repeating: shortest)) * 2).rounded(.toNearestOrAwayFromZero) / 2
        // A step of one pixel on a 14 pt bar is invisible: draw from two.
        let change = target - shown
        guard (change * change).max() >= 1 else { return nil }
        return target
    }

    func apply(_ heights: LevelMeter.Levels) {
        let previous = shown
        shown = heights
        Self.commits += 1
        // Only the bars that moved: every changed layer costs the commit.
        for index in bars.indices where heights[index] != previous[index] {
            bars[index].bounds.size.height = CGFloat(heights[index])
        }
    }
}

/// What a pull request notice says, most pressing first.
enum PullTone: Equatable {
    case failed, changes, merged

    var symbol: String {
        switch self {
        case .failed: "exclamationmark.circle.fill"
        case .changes: "text.bubble.fill"
        case .merged: "arrow.triangle.merge"
        }
    }

    var color: NSColor {
        switch self {
        case .failed: .systemRed
        case .changes: .systemOrange
        case .merged: .systemPurple
        }
    }
}
