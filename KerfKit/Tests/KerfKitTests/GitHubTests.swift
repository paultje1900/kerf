import Foundation
import Testing
@testable import KerfKit

struct GitHubTests {
    @Test func decodesRepos() throws {
        let data = Data(#"[{"isPrivate":true,"nameWithOwner":"octocat/tempo","pushedAt":"2026-10-30T16:43:57Z"}]"#.utf8)
        let repos = try #require(GitHub.decode([GitHub.Repo].self, from: data))
        #expect(repos.first?.name == "tempo")
        #expect(repos.first?.pushedAt != nil)
    }

    @Test func runStates() throws {
        let data = Data(#"[{"status":"completed","conclusion":"failure","url":"u1"},{"status":"in_progress","url":"u2"},{"status":"completed","conclusion":"success","url":"u3"}]"#.utf8)
        let runs = try #require(GitHub.decode([GitHub.Run].self, from: data))
        #expect(runs.map(\.state) == [.failed, .running, .passed])
    }

    @Test func treeChildren() {
        let tree = GitHub.tree(from: Data(#"{"tree":[{"path":"README.md","type":"blob"},{"path":"Atlas","type":"tree"},{"path":"Atlas/App.swift","type":"blob"},{"path":"Atlas/Views","type":"tree"},{"path":"Atlas/Views/Today.swift","type":"blob"},{"path":"apps","type":"tree"}]}"#.utf8))
        #expect(GitHub.children(of: "", in: tree).map(\.name) == ["apps", "Atlas", "README.md"])
        #expect(GitHub.children(of: "Atlas", in: tree).map(\.name) == ["Views", "App.swift"])
    }
}

struct BranchGraphTests {
    private func commit(_ id: String, _ minute: Int, _ parents: [String], branches: [String] = []) -> GitHub.Commit {
        GitHub.Commit(id: id, headline: id, date: Date(timeIntervalSince1970: TimeInterval(minute * 60)), parents: parents, branches: branches)
    }

    /// main: A → B → M (merges feature), feature: A → F1 → F2.
    private var history: [GitHub.Commit] {
        [commit("A", 0, []), commit("B", 2, ["A"]), commit("F1", 1, ["A"]), commit("F2", 3, ["F1"], branches: ["feature"]),
         commit("M", 4, ["B", "F2"], branches: ["main"])]
    }

    @Test func childrenComeBeforeParents() {
        // F2's clock is behind B's child M, but a skewed clock never puts a parent first.
        let skewed = history + [commit("C", -5, ["M"])]
        #expect(GitHub.ordered(skewed).map(\.id) == ["C", "M", "F2", "B", "F1", "A"])
    }

    @Test func lanesFollowMergesAndForks() {
        let rows = GitHub.graph(GitHub.ordered(history))
        #expect(rows.map(\.commit.id) == ["M", "F2", "B", "F1", "A"])
        let m = rows[0], f2 = rows[1], b = rows[2], f1 = rows[3], a = rows[4]
        #expect(m.lane == 0 && m.outgoing == [0, 1] && m.incoming.isEmpty)
        #expect(f2.lane == 1 && f2.incoming == [1] && f2.through == [0])
        #expect(b.lane == 0 && b.through == [1])
        #expect(f1.lane == 1 && f1.through == [0])
        // The feature lane joins main where it forked off.
        #expect(a.lane == 0 && a.incoming == [0, 1] && a.outgoing.isEmpty)
        #expect(rows.map(\.width).max() == 2)
    }

    @Test func readsTheBranchQuery() throws {
        let json = #"""
        {"data":{"repository":{"refs":{"nodes":[
          {"name":"main","target":{"oid":"M","history":{"nodes":[
            {"oid":"M","messageHeadline":"Merge feature","committedDate":"2026-10-31T12:04:00Z","parents":{"nodes":[{"oid":"B"},{"oid":"F2"}]}},
            {"oid":"B","messageHeadline":"Fix","committedDate":"2026-10-31T12:02:00Z","parents":{"nodes":[{"oid":"A"}]}}]}}},
          {"name":"feature","target":{"oid":"F2","history":{"nodes":[
            {"oid":"F2","messageHeadline":"Feature","committedDate":"2026-10-31T12:03:00Z","parents":{"nodes":[{"oid":"A"}]}}]}}}]}}}}
        """#
        let commits = GitHub.commits(fromBranchQuery: Data(json.utf8))
        #expect(commits.map(\.id) == ["M", "F2", "B"])
        #expect(commits.first?.branches == ["main"] && commits[1].branches == ["feature"])
        // A is older than the window: its lines end at its children.
        #expect(GitHub.graph(commits).allSatisfy { $0.outgoing.allSatisfy { $0 < 2 } })
    }
}

struct GitHubSearchTests {
    @Test func checksAndReviews() throws {
        let data = Data(#"""
        {"data":{"search":{"nodes":[
          {"number":42,"title":"Waiting dot","url":"https://github.com/o/kerf/pull/42","isDraft":false,"updatedAt":"2026-11-03T15:43:58Z",
           "reviewDecision":"CHANGES_REQUESTED","repository":{"nameWithOwner":"o/kerf"},
           "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE"}}}]}},
          {"number":7,"title":"No CI","url":"https://github.com/o/tempo/pull/7","isDraft":true,"updatedAt":"2026-11-02T10:00:00Z",
           "reviewDecision":null,"repository":{"nameWithOwner":"o/tempo"},"commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}},
          {}
        ]}}}
        """#.utf8)
        let pulls = try #require(GitHub.pulls(fromSearch: data))
        #expect(pulls.count == 2)
        #expect(pulls[0].checks == .failing)
        #expect(pulls[0].changesRequested == true)
        #expect(pulls[0].updatedAt != nil)
        #expect(pulls[1].checks == nil)
        #expect(pulls[1].isDraft == true)
        #expect(GitHub.searchQuery(login: "JJWindt").contains("author:JJWindt"))
        #expect(!GitHub.searchQuery(login: "JJWindt").contains("involves:"))
        #expect(GitHub.searchQuery(login: "JJWindt", reviews: true).contains("review-requested:JJWindt"))
        let merged = GitHub.searchQuery(login: "JJWindt", mergedSince: Date(timeIntervalSince1970: 0))
        #expect(merged.contains("is:merged author:JJWindt merged:>=1970-01-01T00:00:00Z") && merged.contains("mergedAt"))
        #expect(!merged.contains("is:open"))
    }
}
