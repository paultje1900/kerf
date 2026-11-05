import SwiftUI

/// What every island shows: the compact presentation picked from all modules, whether an agent
/// waits, and which pages exist. Modules report changes; islands follow.
@Observable
final class Hub {
    static let shared = Hub()

    private(set) var presentation: CompactPresentation?
    /// How many threads are blocked on you; the orange dot shows while it's above zero.
    private(set) var waitingCount = 0
    var agentWaiting: Bool { waitingCount > 0 }
    private(set) var pages: [IslandPage] = IslandPage.arrange(offloadActive: false).bar
    /// Pages under "…".
    private(set) var morePages: [IslandPage] = IslandPage.arrange(offloadActive: false).more
    /// The page to open on when something asks for attention.
    var attentionPage: IslandPage? {
        let pullsCall = GitHubModule.shared.attentionCount > 0
        // A waiting agent, or a thread's notice: the AI page lists them, a click opens the chat.
        if agentWaiting || !AgentCenter.shared.notices.isEmpty || (pullsCall && Feature.agents.isOn) { return .agents }
        // Without the agents, pull requests have their own page.
        if pullsCall { return .github }
        if OffloadModule.shared.isActive { return .offload }
        // Clicking what the compact island shows opens its page, as tapping a Live Activity does.
        return switch presentation {
        case .timer: .timer
        default: nil
        }
    }
    /// The page to open on otherwise.
    var startPage: IslandPage? { IslandPage.start(bar: pages, more: morePages) }
    /// A short message on top of everything for a few seconds.
    private var banner: CompactPresentation?
    /// Volume or brightness while it changes.
    private var level: CompactPresentation?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [() -> Void] = []

    func observe(_ action: @escaping () -> Void) {
        observers.append(action)
    }

    func flash(_ presentation: CompactPresentation, seconds: Double = 2.5) {
        banner = presentation
        refresh()
        bannerTask?.cancel()
        bannerTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            banner = nil
            refresh()
        }
    }

    /// Shows a level like the macOS HUD would, and hides it a moment after the last change.
    func show(_ kind: LevelKind, _ value: Double, seconds: Double = 1.4) {
        level = .level(kind, value)
        refresh()
        levelTask?.cancel()
        levelTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            level = nil
            refresh()
        }
    }

    /// Picks what the compact island shows, highest priority first.
    /// Only sets what changed: every set redraws the views that read it.
    func refresh() {
        let agents = AgentCenter.shared
        let waiting = agents.waitingSessions
        if waitingCount != waiting.count { waitingCount = waiting.count }
        let offload = OffloadModule.shared
        let arranged = IslandPage.arrange(offloadActive: offload.isActive)
        if pages != arranged.bar { pages = arranged.bar }
        if morePages != arranged.more { morePages = arranged.more }
        let notices = agents.notices
        var notice: CompactPresentation?
        if let newest = notices.first {
            notice = .agentNotice(agent: newest.agent, hostPath: newest.hostPath, count: notices.count,
                                  needsInput: notices.contains(where: \.needsInput), failed: notices.contains { $0.failure != nil })
        }
        let busy: CompactPresentation? = level ?? banner ?? offload.compactPresentation ?? TimerModule.shared.compactPresentation
            ?? RenderWatcher.shared.compactPresentation ?? DownloadsWatcher.shared.compactPresentation
        let waitingAgent: CompactPresentation? = waiting.first.map { .agent(agent: $0.agent, hostPath: $0.hostPath) }
        let pulls = GitHubModule.shared
        let pullNotice: CompactPresentation? = pulls.attentionCount > 0
            ? .pullNotice(count: pulls.attentionCount, failed: pulls.hasFailedChecks) : nil
        let new = busy ?? notice ?? pullNotice ?? NowPlayingModule.shared.compactPresentation ?? waitingAgent
        if presentation != new { presentation = new }
        observers.forEach { $0() }
    }
}
