import Foundation
import Testing
@testable import KerfKit

struct RequestNavigationTests {
    @Test func opensDecisionAndSelectsFromThreadsWithoutRemovingRequests() {
        let ids = [UUID(), UUID(), UUID()]
        var navigation = RequestNavigation()
        navigation.update(ids)
        #expect(navigation.selectedID == ids[0])
        navigation.overview()
        #expect(navigation.showsOverview)
        #expect(navigation.ids == ids)
        navigation.select(ids[2])
        #expect(navigation.selectedID == ids[2])
        #expect(!navigation.showsOverview)
        navigation.openOldest()
        #expect(navigation.selectedID == ids[0])
        #expect(!navigation.showsOverview)
        navigation.overview()
        navigation.select(UUID())
        #expect(navigation.showsOverview)
        #expect(navigation.selectedID == ids[0])
    }

    @Test func updatesDoNotStealSelectionOrLeaveAStaleRequest() {
        let ids = [UUID(), UUID(), UUID()]
        var navigation = RequestNavigation()
        navigation.update(Array(ids.prefix(2)))
        navigation.select(ids[1])
        navigation.update(ids)
        #expect(navigation.selectedID == ids[1])
        navigation.update([ids[0], ids[2]])
        #expect(navigation.selectedID == ids[2])
        navigation.overview()
        navigation.update([ids[0]])
        #expect(navigation.showsOverview)
        #expect(navigation.selectedID == ids[0])
        navigation.update([])
        #expect(navigation.selectedID == nil)
        navigation.update([ids[2]])
        #expect(navigation.showsOverview)
        navigation.openOldest()
        #expect(navigation.selectedID == ids[2])
        #expect(!navigation.showsOverview)
    }
}

struct RepositoryContextTests {
    @Test func matchesForkHeadRatherThanBaseRepositoryOrBranchAlone() {
        let context = RepositoryContext(id: "/repo/.git", branch: "feature", revision: "", repositories: ["me/kerf"])
        var pull = makePull()
        pull.headRefName = "feature"
        pull.headRepository = .init(nameWithOwner: "Me/Kerf")
        #expect(context.matches(pull))
        pull.headRepository = .init(nameWithOwner: "someone/kerf")
        #expect(!context.matches(pull))
        pull.headRepository = .init(nameWithOwner: "me/kerf")
        pull.headRefName = "other"
        #expect(!context.matches(pull))
        pull.headRefName = nil
        #expect(!context.matches(pull))
    }

    @Test func onlySharedRepositoriesNeedBranchLabels() {
        let first = RepositoryContext(id: "/repo/.git", branch: "main", revision: "", repositories: [])
        var second = first
        second.branch = "fix/queue"
        let unrelated = RepositoryContext(id: "/elsewhere/repo/.git", branch: "main", revision: "", repositories: [])
        #expect(!RepositoryContext.needsBranch(first, among: [first]))
        #expect(!RepositoryContext.needsBranch(first, among: [first, unrelated]))
        #expect(RepositoryContext.needsBranch(first, among: [first, second]))
        #expect(RepositoryContext.needsBranch(first, among: [first, first]))
    }

    @Test func recognizesGitHubRemotes() {
        for remote in ["git@github.com:Me/Repo.git", "https://github.com/Me/Repo.git", "ssh://git@github.com/Me/Repo.git"] {
            #expect(RepositoryContext.githubRepository(remote) == "me/repo")
        }
        #expect(RepositoryContext.githubRepository("https://gitlab.com/me/repo") == nil)
        #expect(RepositoryContext.githubRepository("/local/repo") == nil)
    }

    @Test func readsBranchesWorktreesAndDetachedHeads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kerf-context-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", directory.path, "-c", "core.hooksPath=/dev/null"] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        #expect(try RepositoryContext.read(at: directory.path) == nil)
        try git(["init", "-b", "main"])
        #expect(try RepositoryContext.read(at: directory.path)?.branch == "main")
        try git(["-c", "user.name=Kerf Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
                 "commit", "--allow-empty", "-m", "Fixture"])
        try git(["remote", "add", "origin", "git@github.com:Me/Kerf.git"])
        let main = try #require(try RepositoryContext.read(at: directory.path))
        #expect(main.repositories == ["me/kerf"])
        let worktree = directory.appendingPathComponent("worktree")
        try git(["worktree", "add", "-b", "fix/queue", worktree.path])
        let branch = try #require(try RepositoryContext.read(at: worktree.path))
        #expect(branch.id == main.id)
        #expect(branch.branch == "fix/queue")
        try git(["checkout", "--detach"])
        let detached = try #require(try RepositoryContext.read(at: directory.path))
        #expect(detached.branch == nil)
        #expect(!detached.revision.isEmpty)
    }
}

struct PullAttentionTests {
    @Test func baselineAndUnchangedRefreshesAreQuiet() throws {
        var pull = makePull(checks: .failing, review: true)
        var attention = GitHub.Attention()
        attention.update([pull])
        #expect(attention.unread.isEmpty)
        attention.update([pull])
        #expect(attention.unread.isEmpty)
        pull.checks = .passing
        pull.changesRequested = false
        attention.update([pull])
        pull.checks = .failing
        attention.update([pull])
        #expect(attention.unread[pull.id]?.checksFailed == true)
        attention.acknowledge(pull.id)
        attention.update([pull])
        #expect(attention.unread.isEmpty)
        let saved = try JSONEncoder().encode(attention)
        var restored = try JSONDecoder().decode(GitHub.Attention.self, from: saved)
        restored.update([pull])
        #expect(restored.unread.isEmpty)
        pull.checks = nil
        restored.update([pull])
        pull.checks = .failing
        restored.update([pull])
        #expect(restored.unread.isEmpty)
    }

    @Test func newFailuresReviewsRecoveryAndClosure() {
        var pull = makePull()
        var attention = GitHub.Attention()
        attention.update([])
        pull.checks = .failing
        attention.update([pull])
        #expect(attention.unread[pull.id]?.checksFailed == true)
        pull.changesRequested = true
        attention.update([pull])
        #expect(attention.unread[pull.id]?.changesRequested == true)
        pull.checks = .passing
        attention.update([pull])
        #expect(attention.unread[pull.id]?.checksFailed == false)
        #expect(attention.unread[pull.id]?.changesRequested == true)
        pull.changesRequested = false
        attention.update([pull])
        #expect(attention.unread.isEmpty)
        pull.checks = .failing
        attention.update([pull])
        #expect(attention.unread.count == 1)
        attention.update([])
        #expect(attention.unread.isEmpty)
    }

    @Test func mergesAreNewsOnceAndOnlyAfterTheFirstLook() throws {
        var merged = makePull()
        merged.mergedAt = .now
        var attention = GitHub.Attention()
        attention.updateMerged([merged])
        #expect(attention.unreadMerges.isEmpty)
        var another = merged
        another.url += "-2"
        attention.updateMerged([merged, another])
        #expect(attention.unreadMerges == [another.id])
        attention.updateMerged([merged, another])
        #expect(attention.unreadMerges == [another.id])
        attention.sawMerges()
        attention.updateMerged([merged, another])
        #expect(attention.unreadMerges.isEmpty)
        // Older saved states, from before merges, still load.
        let old = Data(#"{"previous":{},"initialized":true,"unread":{}}"#.utf8)
        #expect(try JSONDecoder().decode(GitHub.Attention.self, from: old).unreadMerges.isEmpty)
    }

    @Test func linkedPRsComeFirstWithoutDroppingOtherAuthoredPRs() {
        var linked = makePull()
        linked.headRefName = "feature"
        linked.headRepository = .init(nameWithOwner: "me/kerf")
        linked.updatedAt = .distantPast
        var other = makePull()
        other.url += "-other"
        other.updatedAt = .now
        let context = RepositoryContext(id: "/repo/.git", branch: "feature", revision: "", repositories: ["me/kerf"])
        #expect(GitHub.prioritized([other, linked], contexts: [context]).map(\.id) == [linked.id, other.id])
        #expect(GitHub.prioritized([other, linked], contexts: []).map(\.id) == [other.id, linked.id])
    }

    @Test func paginationAndErrors() throws {
        let data = Data(#"{"data":{"search":{"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":"next"}}}}"#.utf8)
        #expect(try #require(GitHub.page(fromSearch: data)).nextCursor == "next")
        #expect(GitHub.searchQuery(login: "me", cursor: "next").contains("after: \"next\""))
        #expect(GitHub.page(fromSearch: Data(#"{"errors":[{"message":"failure"}],"data":{"search":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}"#.utf8)) == nil)
        #expect(GitHub.page(fromSearch: Data(#"{"data":{"search":{"nodes":[],"pageInfo":{"hasNextPage":true}}}}"#.utf8)) == nil)
    }
}

private func makePull(checks: GitHub.Item.Checks = .passing, review: Bool = false) -> GitHub.Item {
    .init(number: 1, title: "Test", repository: .init(nameWithOwner: "upstream/kerf"),
          url: "https://github.com/upstream/kerf/pull/1", checks: checks, changesRequested: review)
}
