import AppKit
import KerfKit
import SwiftUI

/// Pull requests, a repo's branches and merges, CI, issues and files, through the GitHub CLI you
/// is signed in to.
@Observable
final class GitHubModule {
    static let shared = GitHubModule()

    enum Tab: String, CaseIterable, Identifiable {
        case pulls, branches, ci, issues, files
        var id: String { rawValue }

        var title: LocalizedStringResource {
            switch self {
            case .pulls: "PRs"
            case .branches: "Branches"
            case .ci: "CI"
            case .issues: "Issues"
            case .files: "Files"
            }
        }
    }

    var tab = Tab.pulls
    private(set) var pulls: [GitHub.Item] = []
    private(set) var issues: [GitHub.Item] = []
    private(set) var runs: [GitHub.Run] = []
    private(set) var repos: [GitHub.Repo] = []
    private(set) var tree: [GitHub.TreeEntry] = []
    /// The chosen repo's recent commits over its branches, in lanes.
    private(set) var graph: [GitHub.GraphRow] = []
    @ObservationIgnored private var graphRepo: String?
    private(set) var repo: GitHub.Repo?
    var folder = ""
    private(set) var isLoading = false
    private(set) var problem: String?
    /// What changed on your PRs since you last looked: failed checks, requested changes.
    private(set) var attention = GitHub.Attention()
    /// Your GitHub login, for the pull request search; checked on every refresh, as the alerts
    /// are per account.
    @ObservationIgnored private var login: String?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var loadedAt = Date.distantPast

    nonisolated static var executable: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/gh" }
        return (["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "\(home)/.local/bin/gh"] + paths)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `gh` off the main thread.
    nonisolated static func gh(_ arguments: [String]) async -> Data? {
        guard let executable else { return nil }
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        }.value
    }

    /// Pull requests with their checks and reviews, which `gh search prs` leaves out.
    nonisolated static func searchPulls(_ query: String?) async -> Data? {
        guard let query, !query.isEmpty else { return nil }
        return await gh(["api", "graphql", "-f", "query=\(query)"])
    }

    /// At most every two minutes, when the page opens.
    func refreshIfStale() {
        guard Date().timeIntervalSince(loadedAt) > 120, !isLoading else { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard Feature.github.isOn else { return }
        guard Self.executable != nil else {
            problem = String(localized: "Install the GitHub CLI (gh) and sign in.")
            return
        }
        isLoading = true
        await refreshPulls()
        async let issues = Self.gh(["search", "issues", "--assignee", "@me", "--state", "open", "--json", "number,title,repository,url,updatedAt", "--limit", "8"])
        async let repos = Self.gh(["repo", "list", "--limit", "100", "--json", "nameWithOwner,pushedAt,isPrivate"])
        let (i, r) = await (issues, repos)
        guard let r else {
            problem = String(localized: "gh isn't signed in. Run gh auth login in Terminal.")
            isLoading = false
            return
        }
        problem = nil
        self.issues = i.flatMap { GitHub.decode([GitHub.Item].self, from: $0) } ?? []
        self.repos = (GitHub.decode([GitHub.Repo].self, from: r) ?? []).sorted { ($0.pushedAt ?? .distantPast) > ($1.pushedAt ?? .distantPast) }
        if repo == nil { repo = self.repos.first }
        // CI of the four repos pushed to last.
        var runs: [GitHub.Run] = []
        await withTaskGroup(of: [GitHub.Run].self) { group in
            for repo in self.repos.prefix(4) {
                group.addTask {
                    guard let data = await Self.gh(["run", "list", "--repo", repo.nameWithOwner, "--limit", "2", "--json",
                                                    "status,conclusion,name,headBranch,createdAt,url,displayTitle"]) else { return [] }
                    return (GitHub.decode([GitHub.Run].self, from: data) ?? []).map { var run = $0; run.repo = repo.name; return run }
                }
            }
            for await found in group { runs += found }
        }
        self.runs = runs.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        loadedAt = .now
        isLoading = false
        if tab == .files { await loadTree() }
        if tab == .branches { await loadGraph() }
        IslandManager.current?.refit()
    }

    /// Your PRs every two minutes while Kerf runs, so a failed check reaches the notch.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                await refreshPulls()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    /// Switched off: no more `gh`, and no pull requests beside the threads.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        login = nil
        pulls = []
        attention = GitHub.Attention()
        Hub.shared.refresh()
    }

    /// Your open PRs and the ones asking you for a review, the ones a thread works on first. A
    /// failed fetch keeps the last list.
    func refreshPulls() async {
        guard Feature.github.isOn else { return }
        guard let data = await Self.gh(["api", "user", "--jq", ".login"]) else { return }
        let current = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return }
        if current != login {
            // Another account: its own PRs and its own alert history.
            login = current
            pulls = []
            attention = UserDefaults.standard.data(forKey: attentionKey)
                .flatMap { try? JSONDecoder().decode(GitHub.Attention.self, from: $0) } ?? GitHub.Attention()
        }
        // Yours merged in the last eight hours stay in the list that long.
        guard let authored = await Self.searchAll(login: current, reviews: false),
              let reviews = await Self.searchAll(login: current, reviews: true),
              let merged = await Self.searchAll(login: current, reviews: false, mergedSince: .now.addingTimeInterval(-8 * 3_600)),
              Feature.github.isOn else { return }
        let requested = reviews.filter { review in !authored.contains { $0.id == review.id } }.map { pull in
            var pull = pull
            pull.reviewRequested = true
            return pull
        }
        pulls = authored + requested + merged
        observe(pulls)
        saveAttention()
        prioritize()
        Hub.shared.refresh()
        IslandManager.current?.refit()
    }

    /// Every page of one pull request search.
    nonisolated static func searchAll(login: String, reviews: Bool, mergedSince: Date? = nil) async -> [GitHub.Item]? {
        var found: [GitHub.Item] = []
        var cursor: String?
        var seen: Set<String> = []
        repeat {
            guard let data = await searchPulls(GitHub.searchQuery(login: login, cursor: cursor, reviews: reviews, mergedSince: mergedSince)),
                  let page = GitHub.page(fromSearch: data) else { return nil }
            found += page.pulls
            cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted { return nil }
        } while cursor != nil
        return found
    }

    /// The PRs tab lists open ones; the AI page also the ones merged lately.
    var openPulls: [GitHub.Item] { pulls.filter { $0.mergedAt == nil } }

    var attentionCount: Int { attention.unread.count + attention.unreadMerges.count }
    /// The most pressing news, for the closed notch.
    var tone: PullTone {
        if attention.unread.values.contains(where: \.checksFailed) { return .failed }
        return attention.unread.isEmpty ? .merged : .changes
    }

    /// Alerts for your open PRs, news for your merged ones; a review request shows in the list,
    /// it doesn't call.
    private func observe(_ pulls: [GitHub.Item]) {
        let own = pulls.filter { $0.reviewRequested != true }
        attention.update(own.filter { $0.mergedAt == nil })
        attention.updateMerged(own.filter { $0.mergedAt != nil })
    }

    /// The list was on screen: merges need nothing more.
    func sawMerges() {
        guard !attention.unreadMerges.isEmpty else { return }
        attention.sawMerges()
        saveAttention()
        Hub.shared.refresh()
    }
    func needsAttention(_ pull: GitHub.Item) -> Bool { attention.unread[pull.id] != nil }

    /// PRs a thread works on (its repository and branch) first.
    func prioritize() {
        pulls = GitHub.prioritized(pulls, contexts: AgentCenter.shared.visibleThreads.compactMap(\.repository))
    }

    private var attentionKey: String { "github.pullAttention.\(login ?? "")" }

    private func saveAttention() {
        UserDefaults.standard.set(try? JSONEncoder().encode(attention), forKey: attentionKey)
    }

    /// The tab's own data, the first time it shows.
    func show(_ tab: Tab) {
        self.tab = tab
        switch tab {
        case .files: Task { await loadTree() }
        case .branches: Task { await loadGraph() }
        default: break
        }
    }

    func choose(_ repo: GitHub.Repo) {
        self.repo = repo
        folder = ""
        tree = []
        graph = []
        graphRepo = nil
        show(tab)
    }

    func loadGraph() async {
        guard let repo, graphRepo != repo.nameWithOwner else { return }
        let parts = repo.nameWithOwner.split(separator: "/").map(String.init)
        guard parts.count == 2, let data = await Self.gh(["api", "graphql", "-f", "query=\(GitHub.branchQuery)",
                                                           "-F", "owner=\(parts[0])", "-F", "name=\(parts[1])"]) else { return }
        // Another repo may have been chosen meanwhile.
        guard self.repo == repo else { return }
        graph = GitHub.graph(GitHub.commits(fromBranchQuery: data))
        graphRepo = repo.nameWithOwner
    }

    func open(_ commit: GitHub.Commit) {
        guard let repo else { return }
        open("https://github.com/\(repo.nameWithOwner)/commit/\(commit.id)")
    }

    func loadTree() async {
        guard let repo, tree.isEmpty else { return }
        if let data = await Self.gh(["api", "repos/\(repo.nameWithOwner)/git/trees/HEAD?recursive=1"]) {
            tree = GitHub.tree(from: data)
            IslandManager.current?.refit()
        }
    }

    /// A local clone in ~/GitHub opens the file itself; otherwise github.com.
    func open(_ entry: GitHub.TreeEntry) {
        if entry.isFolder {
            folder = entry.path
            IslandManager.current?.refit()
            return
        }
        guard let repo else { return }
        let local = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("GitHub/\(repo.name)/\(entry.path)")
        if FileManager.default.fileExists(atPath: local.path) {
            NSWorkspace.shared.activateFileViewerSelecting([local])
        } else if let url = URL(string: "https://github.com/\(repo.nameWithOwner)/blob/HEAD/\(entry.path)") {
            NSWorkspace.shared.open(url)
        }
    }

    func up() {
        folder = (folder as NSString).deletingLastPathComponent
        IslandManager.current?.refit()
    }

    /// Lab only; no gh calls or saved alert history. `changed` is a later fetch of the same PRs.
    func preview(pulls: [GitHub.Item], changed: [GitHub.Item]? = nil) {
        attention = GitHub.Attention()
        observe(pulls)
        if let changed { observe(changed) }
        self.pulls = changed ?? pulls
        prioritize()
        loadedAt = .now
        Hub.shared.refresh()
    }

    /// Opening a PR is looking at it: its alert goes.
    func open(_ link: String) {
        guard let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
        guard attention.unread[link] != nil || attention.unreadMerges.contains(link) else { return }
        attention.acknowledge(link)
        saveAttention()
        Hub.shared.refresh()
    }
}
