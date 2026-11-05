import KerfKit
import SwiftUI

/// The open island's pages. Their icons sit in the band beside the notch.
enum IslandPage: String, CaseIterable, Identifiable {
    case home, music, agents, ask, shelf, offload, today, mixer, github, camera, timer, more

    var id: String { rawValue }

    /// Pages you place in Settings: in the bar, under "…", or off. Offload comes and goes with a card.
    static let placeable: [IslandPage] = [.home, .agents, .music, .ask, .shelf, .today, .mixer, .timer, .github, .camera]

    /// A page shows only while its feature is on. The overview puts music and the day side by
    /// side, so it needs both; with one of them it would only repeat that page.
    var isAvailable: Bool {
        switch self {
        case .home: Feature.music.isOn && Feature.calendar.isOn
        case .music: Feature.music.isOn
        case .agents: Feature.agents.isOn
        case .ask: Feature.ask.isOn
        case .shelf: Feature.shelf.isOn || Feature.clipboard.isOn
        case .offload: Feature.offload.isOn
        case .today: Feature.calendar.isOn || Feature.weather.isOn
        case .github: Feature.github.isOn
        case .camera: Feature.camera.isOn
        case .timer: Feature.timer.isOn
        case .mixer: Feature.mixer.isOn
        case .more: true
        }
    }

    /// In the bar unless placed elsewhere: what doesn't fit goes under "…" by itself.
    var placement: PagePlacement {
        get { UserDefaults.standard.string(forKey: placementKey).flatMap(PagePlacement.init) ?? .bar }
        nonmutating set { UserDefaults.standard.set(newValue.rawValue, forKey: placementKey) }
    }

    var placementKey: String { "page.\(rawValue).placement" }

    /// What the island opens on when nothing asks for attention: the overview, else the threads.
    static func start(bar: [IslandPage], more: [IslandPage]) -> IslandPage? {
        [.home, .agents].first { bar.contains($0) || more.contains($0) } ?? bar.first
    }

    /// The bar holds four icons on each side of the notch, "…" included; the rest goes under "…".
    static func arrange(offloadActive: Bool) -> (bar: [IslandPage], more: [IslandPage]) {
        let pages = placeable.filter(\.isAvailable)
        var bar = pages.filter { $0.placement == .bar }
        var more = pages.filter { $0.placement == .more }
        if offloadActive { bar.insert(.offload, at: min(bar.count, 4)) }
        let room = more.isEmpty && bar.count <= 8 ? 8 : 7
        if bar.count > room {
            more = Array(bar[room...]).filter { $0 != .offload } + more
            bar = Array(bar.prefix(room))
        }
        return (bar + (more.isEmpty ? [] : [.more]), more)
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .music: "music.note"
        case .agents: "apple.intelligence"
        case .ask: "sparkle"
        case .shelf: "tray"
        case .offload: "sdcard"
        case .today: "calendar"
        case .github: "chevron.left.forwardslash.chevron.right"
        case .camera: "web.camera"
        case .timer: "timer"
        case .mixer: "slider.vertical.3"
        case .more: "ellipsis"
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .home: "Overview"
        case .music: "Now Playing"
        case .agents: "AI"
        case .ask: "Ask"
        case .shelf: "Shelf"
        case .offload: "Offload"
        case .today: "Today"
        case .github: "GitHub"
        case .camera: "Camera"
        case .timer: "Timer"
        case .mixer: "Mixer"
        case .more: "More"
        }
    }

    /// How tall the page gets before it scrolls: a waiting question and an answer get more room.
    var maxContentHeight: CGFloat {
        switch self {
        case .agents where AgentCenter.shared.selectedRequest != nil: Layout.tallContentHeight
        case .ask where AskModule.shared.isRunning || !AskModule.shared.answer.isEmpty: Layout.tallContentHeight
        default: Layout.maxContentHeight
        }
    }

    /// Height below the band.
    var contentHeight: CGFloat {
        switch self {
        case .home: HomePage.contentHeight
        case .music: 154
        case .agents: AgentsPage.contentHeight
        case .ask: AskPage.contentHeight
        case .shelf: ShelfPage.contentHeight
        case .offload: OffloadPage.contentHeight
        case .today: TodayPage.contentHeight
        case .github: GitHubPage.contentHeight
        case .camera: CameraPage.contentHeight
        case .timer: TimerPage.contentHeight
        case .mixer: MixerPage.contentHeight
        case .more: MorePage.contentHeight
        }
    }
}

struct PageView: View {
    let page: IslandPage

    var body: some View {
        switch page {
        case .home: HomePage()
        case .music: MusicPage()
        case .agents: AgentsPage()
        case .ask: AskPage()
        case .shelf: ShelfPage()
        case .offload: OffloadPage()
        case .today: TodayPage()
        case .github: GitHubPage()
        case .camera: CameraPage()
        case .timer: TimerPage()
        case .mixer: MixerPage()
        case .more: MorePage()
        }
    }
}

/// The page icons, split over both sides of the notch like the iPhone's leading and trailing views.
struct TabBand: View {
    let island: Island

    var body: some View {
        let pages = island.pages
        let half = (pages.count + 1) / 2
        HStack(spacing: 0) {
            tabs(Array(pages.prefix(half))).frame(maxWidth: .infinity)
            // Clicking the notch closes the island again.
            Color.clear.frame(width: island.geometry.style.centerWidth)
                .contentShape(Rectangle())
                .onTapGesture { island.onClose?() }
            tabs(Array(pages.dropFirst(half))).frame(maxWidth: .infinity)
        }
        .opacity(pages.count > 1 ? 1 : 0)
    }

    private func isSelected(_ page: IslandPage) -> Bool {
        page == island.page || (page == .more && !island.pages.contains(island.page))
    }

    private func tabs(_ pages: [IslandPage]) -> some View {
        // Four icons must fit beside the notch: 4 × 17 + 3 × 5 = 83 pt of 97.
        HStack(spacing: 5) {
            ForEach(pages) { page in
                Button {
                    island.select(page)
                } label: {
                    Image(systemName: page.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(isSelected(page) ? 1 : 0.45))
                        .frame(width: 17, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(page.title))
            }
        }
    }
}

/// Today: the date, the weather, and the day's events with their call links, each while it's on.
struct TodayPage: View {
    private let calendar = CalendarModule.shared

    var body: some View {
        VStack(alignment: .leading, spacing: ui(8)) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: ui(10)) {
                    Text(context.date, format: .dateTime.weekday(.wide).day().month(.wide)).font(.page(15, weight: .semibold))
                    Spacer()
                    if let focus = FocusStatus.current {
                        Button { FocusStatus.openSettings() } label: {
                            Label { Text(verbatim: focus) } icon: { Image(systemName: "moon.fill") }
                                .font(.page(12, weight: .semibold)).foregroundStyle(Color(nsColor: .systemIndigo))
                        }
                        .buttonStyle(.plain)
                    }
                    if Feature.weather.isOn { weather }
                    Text(context.date, format: .dateTime.hour().minute()).font(.page(15, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            if Feature.calendar.isOn { agenda }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, ui(20))
        .padding(.top, ui(6))
        .onAppear { calendar.refresh() }
    }

    static var contentHeight: CGFloat {
        44 + (Feature.calendar.isOn ? CGFloat(max(CalendarModule.shared.events.count, 1)) * 46 : 0)
    }

    @ViewBuilder private var weather: some View {
        let weather = WeatherModule.shared
        if let now = weather.now {
            HStack(spacing: ui(4)) {
                Image(systemName: now.symbol).symbolRenderingMode(.multicolor)
                Text(verbatim: "\(Int(now.temperature.rounded()))°")
                if let rain = now.rainAt {
                    Text(rain <= .now ? "Rain now" : "Rain at \(rain.formatted(date: .omitted, time: .shortened))")
                        .foregroundStyle(Color(nsColor: .systemCyan))
                }
            }
            .font(.page(13, weight: .semibold))
        } else if !weather.isAllowed {
            Button { weather.requestAccess() } label: {
                Image(systemName: "cloud.sun").font(.page(13, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help(Text("Show the weather"))
        }
    }

    @ViewBuilder private var agenda: some View {
        if !calendar.hasAccess {
            Button { calendar.requestAccess() } label: {
                HStack(spacing: ui(10)) {
                    Image(systemName: "calendar.badge.plus").font(.page(15, weight: .semibold))
                    Text("Show your calendar").font(.page(14, weight: .medium))
                    Spacer()
                }
                .frame(height: ui(40))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if calendar.events.isEmpty {
            Text("Nothing in your calendar today").font(.page(14)).foregroundStyle(.white.opacity(0.55)).frame(height: ui(40))
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let next = calendar.next(at: context.date)
                VStack(alignment: .leading, spacing: ui(2)) {
                    ForEach(calendar.events) { event in
                        row(event, isNext: event.id == next?.id, now: context.date)
                    }
                }
            }
        }
    }

    /// One event; what's over is dimmed, the one on now or next gets its call button.
    private func row(_ event: CalendarModule.Event, isNext: Bool, now: Date) -> some View {
        HStack(spacing: ui(10)) {
            Capsule().fill(event.color).frame(width: ui(4), height: ui(32))
            VStack(alignment: .leading, spacing: ui(2)) {
                Text(verbatim: event.title).font(.page(14, weight: .semibold)).lineLimit(1)
                Text(event.when(now: now)).font(.page(12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer()
            if isNext, event.joinURL != nil {
                IslandButton(title: "Join", role: .primary) { calendar.join(event) }.frame(width: ui(96))
            }
        }
        .frame(height: ui(42))
        .opacity(event.end <= now ? 0.4 : 1)
        .contentShape(Rectangle())
        .onTapGesture { calendar.openInCalendar() }
    }
}

enum PagePlacement: String, CaseIterable {
    case bar, more, off

    var title: LocalizedStringResource {
        switch self {
        case .bar: "In the bar"
        case .more: "Under …"
        case .off: "Off"
        }
    }
}

/// "…": the pages that don't sit in the bar, as tiles like Control Center's.
struct MorePage: View {
    @Environment(Island.self) private var island

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: ui(10)), count: 3), spacing: ui(10)) {
            ForEach(Hub.shared.morePages) { page in
                Button { island.select(page) } label: {
                    VStack(spacing: ui(6)) {
                        Image(systemName: page.symbol).font(.page(20, weight: .semibold))
                        Text(page.title).font(.page(12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: ui(68))
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: ui(16), style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: ui(16), style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, ui(20))
        .padding(.top, ui(6))
    }

    static var contentHeight: CGFloat {
        let rows = (Hub.shared.morePages.count + 2) / 3
        return CGFloat(max(rows, 1)) * 78 + 14
    }
}
