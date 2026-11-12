import Foundation

/// What `gh --json` returns, for the GitHub page.
public enum GitHub {
    public struct Repo: Codable, Equatable, Sendable, Identifiable {
        public var nameWithOwner: String
        public var pushedAt: Date?
        public var isPrivate: Bool?
        public var id: String { nameWithOwner }
        public var name: String { nameWithOwner.split(separator: "/").last.map(String.init) ?? nameWithOwner }
    }

    public struct Item: Codable, Equatable, Sendable, Identifiable {
        public struct Repository: Codable, Equatable, Sendable {
            public var nameWithOwner: String
        }

        /// A pull request's latest commit's checks, all together.
        public enum Checks: String, Codable, Sendable {
            case passing, failing, pending

            init?(rollup: String?) {
                switch rollup {
                case "SUCCESS": self = .passing
                case "FAILURE", "ERROR": self = .failing
                case "PENDING", "EXPECTED": self = .pending
                default: return nil
                }
            }
        }

        public var number: Int
        public var title: String
        public var repository: Repository
        public var url: String
        public var updatedAt: Date?
        public var isDraft: Bool?
        /// Pull requests only.
        public var checks: Checks?
        /// A reviewer asked for changes. Pull requests only.
        public var changesRequested: Bool?
        public var headRefName: String?
        public var headRepository: Repository?
        /// Someone else's PR that asks you for a review; nil or false for your own.
        public var reviewRequested: Bool?
        /// When it was merged; nil while open.
        public var mergedAt: Date?
        public var id: String { url }
    }

    public struct Page: Sendable {
        public var pulls: [Item]
        public var nextCursor: String?
    }

    /// Your open PRs, with `reviews` the ones asking you for a review, or with `mergedSince` yours
    /// merged since then: one page of a GraphQL search for `gh api graphql -f query=…`, paginated
    /// so session-linked work is not lost behind newer unrelated PRs.
    public static func searchQuery(login: String, cursor: String? = nil, reviews: Bool = false, mergedSince: Date? = nil) -> String {
        let filter = if let mergedSince {
            "is:merged author:\(login) merged:>=\(mergedSince.formatted(.iso8601))"
        } else {
            "is:open " + (reviews ? "review-requested:\(login)" : "author:\(login)")
        }
        let query = String(decoding: JSONValue.string("is:pr \(filter) archived:false sort:updated-desc").encoded(), as: UTF8.self)
        let after = cursor.map { ", after: " + String(decoding: JSONValue.string($0).encoded(), as: UTF8.self) } ?? ""
        return """
        query { search(query: \(query), type: ISSUE, first: 100\(after)) { pageInfo { hasNextPage endCursor } nodes { \
        ... on PullRequest { number title url isDraft updatedAt mergedAt reviewDecision repository { nameWithOwner } \
        headRefName headRepository { nameWithOwner } \
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } } } } }
        """
    }

    public static func page(fromSearch data: Data) -> Page? {
        guard let json = JSONValue.parse(data),
              (json["errors"]?.array ?? []).isEmpty,
              let search = json["data"]?["search"],
              let nodes = search["nodes"]?.array,
              let hasNext = search["pageInfo"]?["hasNextPage"]?.bool,
              let pulls = pulls(fromSearch: data), pulls.count == nodes.count else { return nil }
        let cursor = search["pageInfo"]?["endCursor"]?.string
        guard !hasNext || cursor?.isEmpty == false else { return nil }
        return Page(pulls: pulls, nextCursor: hasNext ? cursor : nil)
    }

    /// The pull requests in a `searchQuery` answer.
    public static func pulls(fromSearch data: Data) -> [Item]? {
        guard let nodes = JSONValue.parse(data)?["data"]?["search"]?["nodes"]?.array else { return nil }
        let dates = ISO8601DateFormatter()
        return nodes.compactMap { node -> Item? in
            guard let number = node["number"]?.number, let title = node["title"]?.string, let url = node["url"]?.string,
                  let repository = node["repository"]?["nameWithOwner"]?.string else { return nil }
            let rollup = node["commits"]?["nodes"]?.array?.first?["commit"]?["statusCheckRollup"]?["state"]?.string
            return Item(number: Int(number), title: title, repository: .init(nameWithOwner: repository), url: url,
                        updatedAt: node["updatedAt"]?.string.flatMap(dates.date(from:)), isDraft: node["isDraft"]?.bool,
                        checks: Item.Checks(rollup: rollup), changesRequested: node["reviewDecision"]?.string == "CHANGES_REQUESTED",
                        headRefName: node["headRefName"]?.string,
                        headRepository: node["headRepository"]?["nameWithOwner"]?.string.map { .init(nameWithOwner: $0) },
                        mergedAt: node["mergedAt"]?.string.flatMap(dates.date(from:)))
        }
    }

    public static func prioritized(_ pulls: [Item], contexts: [RepositoryContext]) -> [Item] {
        pulls.sorted { left, right in
            let leftLinked = contexts.contains { $0.matches(left) }
            let rightLinked = contexts.contains { $0.matches(right) }
            if leftLinked != rightLinked { return leftLinked }
            if left.updatedAt != right.updatedAt { return (left.updatedAt ?? .distantPast) > (right.updatedAt ?? .distantPast) }
            return left.id < right.id
        }
    }

    public struct Attention: Codable, Equatable, Sendable {
        public struct Status: Codable, Equatable, Sendable {
            public var checksFailed: Bool
            public var changesRequested: Bool
            public var isEmpty: Bool { !checksFailed && !changesRequested }
        }

        private var previous: [String: Status] = [:]
        private var initialized = false
        public private(set) var unread: [String: Status] = [:]
        /// Your merged PRs seen so far, and the ones merged since you last looked.
        private var merges: Set<String> = []
        private var mergesInitialized = false
        public private(set) var unreadMerges: Set<String> = []

        public init() {}

        private enum CodingKeys: String, CodingKey {
            case previous, initialized, unread, merges, mergesInitialized, unreadMerges
        }

        /// Older saved states have no merges yet.
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            previous = try values.decode([String: Status].self, forKey: .previous)
            initialized = try values.decode(Bool.self, forKey: .initialized)
            unread = try values.decode([String: Status].self, forKey: .unread)
            merges = try values.decodeIfPresent(Set<String>.self, forKey: .merges) ?? []
            mergesInitialized = try values.decodeIfPresent(Bool.self, forKey: .mergesInitialized) ?? false
            unreadMerges = try values.decodeIfPresent(Set<String>.self, forKey: .unreadMerges) ?? []
        }

        /// Your PRs merged lately: one not seen before is news, except on the first look.
        public mutating func updateMerged(_ pulls: [Item]) {
            let ids = Set(pulls.map(\.id))
            if mergesInitialized { unreadMerges.formUnion(ids.subtracting(merges)) }
            unreadMerges.formIntersection(ids)
            merges = ids
            mergesInitialized = true
        }

        /// You looked at the list.
        public mutating func sawMerges() { unreadMerges = [] }

        public mutating func update(_ pulls: [Item]) {
            var next: [String: Status] = [:]
            var notices: [String: Status] = [:]
            for pull in pulls {
                let old = previous[pull.id]
                let state = Status(checksFailed: pull.checks.map { $0 == .failing } ?? old?.checksFailed ?? false,
                                   changesRequested: pull.changesRequested ?? old?.changesRequested ?? false)
                next[pull.id] = state
                let notice = Status(
                    checksFailed: state.checksFailed && (unread[pull.id]?.checksFailed == true || initialized && old?.checksFailed != true),
                    changesRequested: state.changesRequested && (unread[pull.id]?.changesRequested == true || initialized && old?.changesRequested != true)
                )
                if !notice.isEmpty { notices[pull.id] = notice }
            }
            previous = next
            unread = notices
            initialized = true
        }

        public mutating func acknowledge(_ id: String) {
            unread.removeValue(forKey: id)
            unreadMerges.remove(id)
        }
    }

    public struct Run: Codable, Equatable, Sendable, Identifiable {
        public var status: String
        public var conclusion: String?
        public var name: String?
        public var headBranch: String?
        public var createdAt: Date?
        public var url: String
        public var displayTitle: String?
        public var repo: String?
        public var id: String { url }

        public enum State: Sendable {
            case running, passed, failed, other
        }

        public var state: State {
            if status != "completed" { return .running }
            switch conclusion {
            case "success": return .passed
            case "failure", "timed_out", "startup_failure": return .failed
            default: return .other
            }
        }
    }

    public struct TreeEntry: Codable, Equatable, Sendable, Identifiable {
        public var path: String
        public var type: String
        public var size: Int?
        public var id: String { path }
        public var isFolder: Bool { type == "tree" }
        public var name: String { (path as NSString).lastPathComponent }
    }

    struct Tree: Codable {
        var tree: [TreeEntry]
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? decoder.decode(type, from: data)
    }

    public static func tree(from data: Data) -> [TreeEntry] {
        (try? decoder.decode(Tree.self, from: data))?.tree ?? []
    }

    /// The direct children of a folder ("" is the root), folders first.
    public static func children(of folder: String, in tree: [TreeEntry]) -> [TreeEntry] {
        let prefix = folder.isEmpty ? "" : folder + "/"
        return tree
            .filter { $0.path.hasPrefix(prefix) && !$0.path.dropFirst(prefix.count).contains("/") && !$0.path.dropFirst(prefix.count).isEmpty }
            .sorted { ($0.isFolder ? 0 : 1, $0.name.lowercased()) < ($1.isFolder ? 0 : 1, $1.name.lowercased()) }
    }
}
