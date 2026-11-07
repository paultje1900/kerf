import KerfKit
import SwiftUI

/// Pull requests, a repo's branches and merges, CI runs, issues and a repo's files.
struct GitHubPage: View {
    @Bindable private var github = GitHubModule.shared

    var body: some View {
        VStack(alignment: .leading, spacing: ui(6)) {
            HStack(spacing: ui(6)) {
                ForEach(GitHubModule.Tab.allCases) { tab in
                    Button { github.show(tab) } label: {
                        Text(tab.title).font(.page(12, weight: .semibold))
                            .padding(.horizontal, ui(11)).frame(height: ui(26))
                            .background(.white.opacity(github.tab == tab ? 0.22 : 0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if github.isLoading { ProgressView().controlSize(.mini).tint(.white) }
            }
            if let problem = github.problem {
                Text(verbatim: problem).font(.page(13)).foregroundStyle(.white.opacity(0.6)).frame(height: ui(40))
            } else {
                switch github.tab {
                case .pulls: items(github.openPulls, symbol: "arrow.triangle.pull", empty: "No open pull requests")
                case .branches: branches
                case .issues: items(github.issues, symbol: "smallcircle.filled.circle", empty: "No issues for you")
                case .ci: runs
                case .files: files
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, ui(20))
        .padding(.top, ui(6))
        .onAppear { github.refreshIfStale() }
    }

    static var contentHeight: CGFloat {
        let github = GitHubModule.shared
        let rows: Int = switch github.tab {
        case .pulls: github.openPulls.count
        case .branches: github.graph.count + 1
        case .issues: github.issues.count
        case .ci: github.runs.count
        case .files: GitHub.children(of: github.folder, in: github.tree).count + 1
        }
        return 48 + CGFloat(min(max(rows, 1), 9)) * 32
    }

    private func items(_ items: [GitHub.Item], symbol: String, empty: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty { Text(empty).font(.page(13)).foregroundStyle(.white.opacity(0.55)).frame(height: ui(36)) }
            ForEach(items) { item in
                row(symbol: symbol, tint: item.isDraft == true ? .white.opacity(0.5) : Color(nsColor: .systemGreen), title: item.title,
                    detail: "\(item.repository.nameWithOwner.split(separator: "/").last ?? "") #\(item.number)", date: item.updatedAt) {
                    github.open(item.url)
                }
            }
        }
    }

    private var runs: some View {
        VStack(alignment: .leading, spacing: 0) {
            if github.runs.isEmpty { Text("No recent CI runs").font(.page(13)).foregroundStyle(.white.opacity(0.55)).frame(height: ui(36)) }
            ForEach(github.runs) { run in
                let (symbol, tint): (String, Color) = switch run.state {
                case .running: ("circle.dotted", Color(nsColor: .systemYellow))
                case .passed: ("checkmark.circle.fill", Color(nsColor: .systemGreen))
                case .failed: ("xmark.circle.fill", Color(nsColor: .systemRed))
                case .other: ("minus.circle.fill", .white.opacity(0.5))
                }
                row(symbol: symbol, tint: tint, title: run.displayTitle ?? run.name ?? "", detail: [run.repo, run.headBranch].compactMap { $0 }.joined(separator: " · "),
                    date: run.createdAt) {
                    github.open(run.url)
                }
            }
        }
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: ui(6)) {
                repoMenu
                if !github.folder.isEmpty {
                    Text(verbatim: "/ " + github.folder).font(.page(13)).foregroundStyle(.white.opacity(0.55)).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button { github.up() } label: { Image(systemName: "arrow.up").font(.page(12, weight: .bold)) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Up"))
                }
                Spacer()
            }
            .frame(height: ui(30))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(GitHub.children(of: github.folder, in: github.tree)) { entry in
                    Button { github.open(entry) } label: {
                        HStack(spacing: ui(8)) {
                            Image(systemName: entry.isFolder ? "folder.fill" : "doc").font(.page(12, weight: .semibold))
                                .foregroundStyle(entry.isFolder ? Color(nsColor: .systemBlue) : .white.opacity(0.6))
                                .frame(width: ui(18))
                            Text(verbatim: entry.name).font(.page(13)).lineLimit(1)
                            Spacer()
                        }
                        .frame(height: ui(28))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var repoMenu: some View {
        Menu {
            ForEach(github.repos.prefix(30)) { repo in
                Button(repo.name) { github.choose(repo) }
            }
        } label: {
            Text(verbatim: github.repo?.name ?? "Repo").font(.page(13, weight: .semibold))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }

    /// The repo's newest commits over its branches: where they split off and merge back.
    private var branches: some View {
        let lanes = min(github.graph.map(\.width).max() ?? 1, BranchLines.maxLanes)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                repoMenu
                Spacer()
            }
            .frame(height: ui(30))
            if github.graph.isEmpty, !github.isLoading {
                Text("No commits yet").font(.page(13)).foregroundStyle(.white.opacity(0.55)).frame(height: ui(36))
            }
            ForEach(github.graph) { row in
                Button { github.open(row.commit) } label: {
                    HStack(spacing: ui(8)) {
                        BranchLines(row: row).frame(width: CGFloat(lanes) * BranchLines.laneWidth, height: ui(28))
                        ForEach(row.commit.branches, id: \.self) { name in
                            Text(verbatim: name).font(.page(10, weight: .semibold)).lineLimit(1).fixedSize()
                                .foregroundStyle(BranchLines.color(row.lane))
                                .padding(.horizontal, ui(6)).frame(height: ui(18))
                                .background(BranchLines.color(row.lane).opacity(0.18), in: Capsule())
                        }
                        Text(verbatim: row.commit.headline).font(.page(13, weight: row.commit.isMerge ? .regular : .medium)).lineLimit(1)
                            .foregroundStyle(.white.opacity(row.commit.isMerge ? 0.55 : 1))
                        Spacer(minLength: ui(6))
                        Text(row.commit.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                            .font(.page(11)).foregroundStyle(.white.opacity(0.4))
                    }
                    .frame(height: ui(28))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func row(symbol: String, tint: Color, title: String, detail: String, date: Date?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: ui(10)) {
                Image(systemName: symbol).font(.page(13, weight: .semibold)).foregroundStyle(tint).frame(width: ui(18))
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: title).font(.page(13, weight: .semibold)).lineLimit(1)
                    Text(verbatim: detail).font(.page(11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer()
                if let date {
                    Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow)).font(.page(11)).foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(height: ui(32))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One commit's piece of the branch graph: each lane's line in its own colour, and the commit's
/// dot, hollow for a merge. Rows sit edge to edge, so the lines run on.
struct BranchLines: View {
    let row: GitHub.GraphRow

    static let maxLanes = 6
    static var laneWidth: CGFloat { ui(12) }
    private static let colors: [Color] = [.systemBlue, .systemGreen, .systemOrange, .systemPink, .systemPurple, .systemTeal]
        .map { Color(nsColor: $0) }

    static func color(_ lane: Int) -> Color { colors[lane % colors.count] }

    var body: some View {
        Canvas { context, size in
            func x(_ lane: Int) -> CGFloat { Self.laneWidth * (CGFloat(lane) + 0.5) }
            let middle = size.height / 2
            let dot = CGPoint(x: x(row.lane), y: middle)
            let line = StrokeStyle(lineWidth: 1.5, lineCap: .round)
            for lane in row.through {
                let path = Path { $0.move(to: CGPoint(x: x(lane), y: 0)); $0.addLine(to: CGPoint(x: x(lane), y: size.height)) }
                context.stroke(path, with: .color(Self.color(lane)), style: line)
            }
            for lane in row.incoming {
                let path = Path {
                    $0.move(to: CGPoint(x: x(lane), y: 0))
                    $0.addCurve(to: dot, control1: CGPoint(x: x(lane), y: middle * 0.7), control2: CGPoint(x: dot.x, y: middle * 0.3))
                }
                context.stroke(path, with: .color(Self.color(lane)), style: line)
            }
            for lane in row.outgoing {
                let path = Path {
                    $0.move(to: dot)
                    $0.addCurve(to: CGPoint(x: x(lane), y: size.height), control1: CGPoint(x: dot.x, y: middle * 1.7),
                                control2: CGPoint(x: x(lane), y: middle * 1.3))
                }
                context.stroke(path, with: .color(Self.color(lane)), style: line)
            }
            let radius = ui(3.5)
            let circle = Path(ellipseIn: CGRect(x: dot.x - radius, y: dot.y - radius, width: radius * 2, height: radius * 2))
            if row.commit.isMerge {
                context.fill(circle, with: .color(.black))
                context.stroke(circle, with: .color(Self.color(row.lane)), lineWidth: 1.5)
            } else {
                context.fill(circle, with: .color(Self.color(row.lane)))
            }
        }
        .accessibilityHidden(true)
    }
}
