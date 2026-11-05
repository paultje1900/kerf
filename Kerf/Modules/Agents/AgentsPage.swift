import KerfKit
import SwiftUI

/// The AI page: a waiting question first, as an Apple island card. Otherwise the threads that run
/// or finished unseen, and open pull requests.
struct AgentsPage: View {
    private let center = AgentCenter.shared
    private let github = GitHubModule.shared

    var body: some View {
        VStack(spacing: ui(8)) {
            if let request = center.selectedRequest {
                Button {
                    center.navigation.overview()
                } label: {
                    Label("Threads", systemImage: "chevron.left")
                        .font(.page(12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.vertical, ui(4))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ui(22))
                Group {
                    switch request.event {
                    case .question(let questions, _):
                        QuestionCard(request: request, questions: questions,
                                     draft: Binding(get: { center.questionDrafts[request.id] ?? QuestionDraft() },
                                                    set: { center.questionDrafts[request.id] = $0 }))
                    default:
                        PermissionCard(request: request)
                    }
                }
                .id(request.id)
            } else {
                Overview(threads: center.visibleThreads, pulls: github.pulls)
            }
        }
        // Finished threads stay until you click them or carries on in their chat.
        .onAppear {
            center.checkConnections()
            center.findRunning()
            github.refreshIfStale()
        }
    }

    static var contentHeight: CGFloat {
        let center = AgentCenter.shared
        if let request = center.selectedRequest {
            if case .question(let questions, _) = request.event {
                let options = questions.first?.options.count ?? 0
                return 32 + 112 + CGFloat((options + 1) / 2) * 46
            }
            return 32 + 204
        }
        let threads = min(center.visibleThreads.count, 4)
        let pulls = min(GitHubModule.shared.pulls.count, 3)
        guard threads + pulls > 0 else { return center.hasConnectedAgent ? 96 : 150 }
        return 22 + (threads > 0 ? 22 + CGFloat(threads) * 46 : 0) + (pulls > 0 ? 22 + CGFloat(pulls) * 38 : 0)
    }
}

/// Threads and pull requests, or a calm empty state.
struct Overview: View {
    let threads: [AgentCenter.Session]
    let pulls: [GitHub.Item]

    var body: some View {
        if threads.isEmpty, pulls.isEmpty {
            VStack(spacing: ui(6)) {
                Image(systemName: "apple.intelligence").font(.page(22, weight: .semibold))
                    .foregroundStyle(AgentMark.gradient)
                if AgentCenter.shared.hasConnectedAgent {
                    Text("No threads running").font(.page(14, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                    Text("Questions from Claude Code, Codex and Copilot show up here.").font(.page(12)).foregroundStyle(.white.opacity(0.4))
                } else {
                    // A fresh install: nothing reaches the notch until an agent is connected.
                    Text("Connect your coding agent").font(.page(14, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                    Text("Claude Code, Codex or Copilot, in Settings → Agents.").font(.page(12)).foregroundStyle(.white.opacity(0.5))
                    IslandButton(title: "Connect…", role: .primary) {
                        IslandManager.current?.closeAll()
                        SettingsOpener.open(tab: .agents)
                    }
                    .frame(width: ui(150))
                    .padding(.top, ui(4))
                }
            }
            .frame(maxWidth: .infinity, minHeight: ui(96))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if !threads.isEmpty {
                    SectionLabel(title: "Threads")
                    ForEach(threads) { ThreadRow(session: $0) }
                }
                if !pulls.isEmpty {
                    SectionLabel(title: "Pull Requests")
                    ForEach(pulls) { pull in
                        Button { GitHubModule.shared.open(pull.url) } label: {
                            HStack(spacing: ui(10)) {
                                Image(systemName: "arrow.triangle.pull").font(.page(13, weight: .semibold))
                                    .foregroundStyle(pull.isDraft == true ? .white.opacity(0.5) : Color(nsColor: .systemGreen))
                                    .frame(width: ui(30))
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(verbatim: pull.title).font(.page(13, weight: .semibold)).lineLimit(1)
                                    PullDetails(pull: pull).font(.page(11))
                                }
                                Spacer()
                                if GitHubModule.shared.needsAttention(pull) {
                                    Circle().fill(Color(nsColor: .systemOrange)).frame(width: ui(6), height: ui(6))
                                        .accessibilityLabel(Text("Needs your attention"))
                                }
                                if let date = pull.updatedAt {
                                    Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                                        .font(.page(11)).foregroundStyle(.white.opacity(0.4))
                                }
                            }
                            .frame(height: ui(34))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, ui(20))
            .padding(.top, ui(4))
        }
    }
}

/// "kerf #42 · Checks failed": only what asks for you, the rest stays quiet.
struct PullDetails: View {
    let pull: GitHub.Item

    var body: some View {
        let name = Text(verbatim: "\(pull.repository.nameWithOwner.split(separator: "/").last ?? "") #\(pull.number)")
            .foregroundStyle(.white.opacity(0.5))
        if let status {
            Text("\(name) · \(status)")
        } else {
            name
        }
    }

    private var status: Text? {
        if pull.reviewRequested == true {
            Text("Review requested").foregroundStyle(.white.opacity(0.5))
        } else if pull.checks == .failing {
            Text("Checks failed").foregroundStyle(Color(nsColor: .systemRed))
        } else if pull.changesRequested == true {
            Text("Changes requested").foregroundStyle(Color(nsColor: .systemOrange))
        } else if pull.checks == .pending {
            Text("Checks running").foregroundStyle(.white.opacity(0.5))
        } else {
            nil
        }
    }
}

struct SectionLabel: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title).font(.page(12, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
            .frame(height: ui(22), alignment: .bottom)
    }
}

/// One thread: the agent, what was asked, and whether it runs, waits or is done.
struct ThreadRow: View {
    let session: AgentCenter.Session
    private let center = AgentCenter.shared
    @State private var answerHovered = false

    var body: some View {
        let request = center.request(for: session)
        HStack(spacing: ui(10)) {
            Button(action: open) {
                HStack(spacing: ui(10)) {
                    AgentMark(agent: session.agent, hostPath: session.hostPath, size: ui(30))
                    VStack(alignment: .leading, spacing: ui(1)) {
                        Text(verbatim: session.title ?? session.project ?? session.name).font(.page(14, weight: .semibold)).lineLimit(1)
                        // Once a minute is enough for "12 min".
                        TimelineView(.everyMinute) { context in
                            Text(verbatim: details(at: context.date))
                                .font(.page(12)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if request == nil { indicator.frame(width: ui(28), height: ui(36)) }
                }
                .frame(maxWidth: .infinity, minHeight: ui(46), alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let request {
                Button { center.navigation.select(request.id) } label: {
                    HStack(spacing: ui(6)) {
                        Image(systemName: "text.bubble")
                            .font(.page(13, weight: .medium))
                            .foregroundStyle(.white.opacity(answerHovered ? 0.95 : 0.75))
                        AgentDot(glows: false)
                    }
                    .padding(.horizontal, ui(8))
                    .frame(height: ui(26))
                    .background(.white.opacity(answerHovered ? 0.16 : 0.08), in: Capsule())
                    .frame(minWidth: ui(44), minHeight: ui(36))
                    .contentShape(Rectangle())
                    .animation(.easeOut(duration: 0.12), value: answerHovered)
                }
                .buttonStyle(.plain)
                .onHover { answerHovered = $0 }
                .help(Text("Answer…"))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Answer…"))
                .accessibilityHint(Text("Show this thread's decision in Kerf"))
            }
        }
        .frame(height: ui(46))
    }

    /// "Waiting for you · 12 min · 2 subagents · kerf", "Done 5 min ago · atlas".
    private func details(at now: Date) -> String {
        let elapsed = now.timeIntervalSince(session.stateSince)
        var parts = [stateText]
        if elapsed >= 60 {
            if session.state == .idle {
                parts[0] += " " + session.stateSince.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
            } else {
                parts.append(Duration.seconds(elapsed).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
            }
        }
        if let subagentsText { parts.append(subagentsText) }
        if let project = AgentCenter.shared.projectLabel(for: session) { parts.append(project) }
        return parts.joined(separator: " · ")
    }

    /// "2 subagents" while the thread runs them.
    private var subagentsText: String? {
        let count = session.subagents.count
        guard session.state != .idle, count > 0 else { return nil }
        return count == 1 ? String(localized: "1 subagent") : String(localized: "\(count) subagents")
    }

    private var stateText: String {
        if let failure = session.failure { return String(localized: "Stopped: \(Self.failureText(failure))") }
        return switch session.state {
        case .working: String(localized: "Working")
        case .waiting: String(localized: "Waiting for you")
        case .idle: String(localized: "Done")
        }
    }

    /// Claude Code's StopFailure `error`, in words.
    static func failureText(_ error: String) -> String {
        switch error {
        case "rate_limit": String(localized: "rate limit reached")
        case "overloaded": String(localized: "Claude is overloaded")
        case "server_error": String(localized: "server error")
        case "max_output_tokens": String(localized: "answer too long")
        case "authentication_failed", "oauth_org_not_allowed", "cloud_credential_error": String(localized: "sign-in problem")
        case "billing_error", "account_on_hold": String(localized: "account problem")
        default: String(localized: "API error")
        }
    }

    @ViewBuilder private var indicator: some View {
        switch session.state {
        case .working:
            Image(systemName: "ellipsis").font(.page(14, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                .symbolEffect(.variableColor.iterative, isActive: true)
        case .waiting:
            AgentDot(glows: false)
        case .idle where session.failure != nil:
            Image(systemName: "exclamationmark.triangle.fill").font(.page(13, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemRed))
                .accessibilityLabel(Text("Stopped on an error"))
        case .idle:
            Circle().fill(Color(nsColor: .systemBlue)).frame(width: ui(8), height: ui(8))
                .accessibilityLabel(Text("Unread"))
        }
    }

    /// The thread's chat.
    private func open() {
        AgentCenter.shared.open(session)
        IslandManager.current?.closeAll()
    }
}

/// An AI agent's mark: its own app icon (Claude, Codex), GitHub's Copilot mark, or an Apple
/// Intelligence-style tile, with the app it runs in as a small badge.
struct AgentMark: View {
    let agent: AgentKind
    let hostPath: String?
    var size: CGFloat = 24

    static let gradient = AngularGradient(colors: [Color(red: 0.25, green: 0.55, blue: 1), Color(red: 0.62, green: 0.38, blue: 1),
                                                   Color(red: 1, green: 0.36, blue: 0.62), Color(red: 1, green: 0.62, blue: 0.25),
                                                   Color(red: 0.25, green: 0.55, blue: 1)], center: .center)

    private static let agentApps: [AgentKind: [String]] = [
        .claudeCode: ["/Applications/Claude.app"],
        .codex: ["/Applications/Codex.app", "/Applications/ChatGPT.app"],
    ]

    var body: some View {
        mark
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: badge)).resizable()
                        .frame(width: size * 0.5, height: size * 0.5)
                        .shadow(color: .black.opacity(0.5), radius: 1.5)
                        .offset(x: size * 0.12, y: size * 0.12)
                }
            }
    }

    private var agentApp: String? {
        Self.agentApps[agent]?.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// The host as a badge, unless it is the agent's own app.
    private var badge: String? {
        guard let hostPath, hostPath != agentApp, FileManager.default.fileExists(atPath: hostPath) else { return nil }
        return hostPath
    }

    @ViewBuilder private var mark: some View {
        if let agentApp {
            Image(nsImage: NSWorkspace.shared.icon(forFile: agentApp)).resizable()
        } else if agent == .copilot {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(Color(white: 0.13))
                .overlay {
                    Image("Copilot").resizable().scaledToFit().foregroundStyle(.white).padding(size * 0.2)
                }
        } else {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(Self.gradient)
                .overlay {
                    Image(systemName: "apple.intelligence").font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
                }
        }
    }
}

/// Laid out like Apple's AirDrop card on the Mac island: mark, title, subtitle, what to allow,
/// then grey, grey and blue capsules.
struct PermissionCard: View {
    let request: AgentCenter.Request

    var body: some View {
        let summary = summary
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                AgentMark(agent: request.agent, hostPath: request.hostPath, size: ui(28))
                Spacer()
            }
            .padding(.bottom, ui(6))
            Text(verbatim: request.name).font(.page(16, weight: .semibold))
            Text(verbatim: [AgentCenter.shared.projectLabel(for: request), String(localized: summary.title)].compactMap { $0 }.joined(separator: " · "))
                .font(.page(14)).foregroundStyle(.white.opacity(0.55))
                .padding(.bottom, ui(10))
            CappedScroll(maxHeight: ui(190)) {
                Text(verbatim: summary.detail)
                    .font(.page(13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ui(12))
                    .padding(.vertical, ui(8))
            }
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: ui(10), style: .continuous))
            .padding(.bottom, ui(12))
            HStack(spacing: ui(10)) {
                IslandButton(title: "Decline") { answer(.deny) }
                    .keyboardShortcut(.cancelAction)
                // Only where the tool can keep it; elsewhere "always" would mean just this once.
                if request.agent.remembersAlways {
                    IslandButton(title: "Always") { answer(.always) }
                        .keyboardShortcut(.return, modifiers: .option)
                }
                IslandButton(title: "Allow", role: .primary) { answer(.allow) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, ui(22))
        .padding(.top, ui(4))
        .contextMenu {
            Button("Ask in \(request.hostPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? request.name)") {
                answer(.passThrough)
            }
        }
    }

    private func answer(_ decision: AgentReply.Decision) {
        AgentCenter.shared.answer(request, AgentReply(decision: decision))
    }

    private var summary: (title: LocalizedStringResource, detail: String) {
        guard case .permission(let tool, let input, _) = request.event else { return ("Wants to continue", "") }
        let summary = ToolSummary(tool: tool, input: input, cwd: request.cwd)
        let title: LocalizedStringResource = switch summary.kind {
        case .command: "Run a command"
        case .edit: "Edit a file"
        case .write: "Write a file"
        case .read: "Read a file"
        case .fetch: "Open a web page"
        case .search: "Search the web"
        case .mcp(let server): "Use \(server)"
        case .other: "Use \(tool)"
        }
        return (title, summary.detail)
    }
}

/// AskUserQuestion: the options as capsules, or a typed answer. Several questions go one by one.
struct QuestionCard: View {
    let request: AgentCenter.Request
    let questions: [AgentQuestion]
    @Binding var draft: QuestionDraft
    @FocusState private var typing: Bool

    var body: some View {
        let question = questions[min(draft.index, questions.count - 1)]
        VStack(alignment: .leading, spacing: ui(10)) {
            HStack(spacing: ui(8)) {
                AgentMark(agent: request.agent, hostPath: request.hostPath, size: ui(22))
                Text(verbatim: request.name).font(.page(14, weight: .semibold))
                if let project = AgentCenter.shared.projectLabel(for: request) {
                    Text(verbatim: project).font(.page(14)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                if questions.count > 1 {
                    Text(verbatim: "\(draft.index + 1)/\(questions.count)").font(.page(12, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                }
            }
            Text(verbatim: question.question).font(.page(15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if Self.fitsCapsules(question.options) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: ui(10)), GridItem(.flexible(), spacing: ui(10))], spacing: ui(10)) {
                    ForEach(question.options) { option in
                        IslandButton(verbatim: option.label, role: draft.picked.contains(option.label) ? .primary : .secondary) {
                            tap(option, in: question)
                        }
                    }
                }
            } else {
                VStack(spacing: ui(8)) {
                    ForEach(question.options) { option in
                        OptionRow(option: option, isPicked: draft.picked.contains(option.label), multiSelect: question.multiSelect) {
                            tap(option, in: question)
                        }
                    }
                }
            }
            HStack(spacing: ui(10)) {
                TextField("Other answer", text: $draft.typed)
                    .textFieldStyle(.plain)
                    .font(.page(14))
                    .padding(.horizontal, ui(14))
                    .frame(height: ui(34))
                    .background(.white.opacity(0.1), in: Capsule())
                    .focused($typing)
                    .onSubmit { if !draft.typed.isEmpty { choose(draft.typed, for: question) } }
                if question.multiSelect {
                    IslandButton(title: "Done", role: .primary) {
                        choose(question.options.map(\.label).filter(draft.picked.contains).joined(separator: ", "), for: question)
                    }
                    .frame(width: ui(90))
                    .disabled(draft.picked.isEmpty)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, ui(22))
        .padding(.top, ui(4))
    }

    /// Short options without a description sit two to a row as capsules; the rest get full rows.
    private static func fitsCapsules(_ options: [AgentQuestion.Option]) -> Bool {
        options.allSatisfy { $0.label.count <= 18 && ($0.description ?? "").isEmpty }
    }

    private func tap(_ option: AgentQuestion.Option, in question: AgentQuestion) {
        if question.multiSelect {
            if draft.picked.contains(option.label) { draft.picked.remove(option.label) } else { draft.picked.insert(option.label) }
        } else {
            choose(option.label, for: question)
        }
    }

    private func choose(_ answer: String, for question: AgentQuestion) {
        draft.answers[question.question] = answer
        draft.picked = []
        draft.typed = ""
        if draft.index + 1 < questions.count {
            draft.index += 1
        } else {
            AgentCenter.shared.answer(request, AgentReply(decision: .allow, answers: draft.answers))
        }
    }
}

/// One answer to a question in full: its label and what it means, wrapped, never cut off.
struct OptionRow: View {
    let option: AgentQuestion.Option
    let isPicked: Bool
    let multiSelect: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: ui(10)) {
                if multiSelect {
                    Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                        .font(.page(14, weight: .semibold))
                        .foregroundStyle(isPicked ? IslandButton.primaryLabel : .white.opacity(0.5))
                }
                VStack(alignment: .leading, spacing: ui(2)) {
                    Text(verbatim: option.label).font(.page(14, weight: .semibold))
                        .foregroundStyle(isPicked ? IslandButton.primaryLabel : .white)
                    if let description = option.description, !description.isEmpty {
                        Text(verbatim: description).font(.page(12)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, ui(14))
            .padding(.vertical, ui(9))
            .background(isPicked ? IslandButton.primaryFill : Color(white: 0.2), in: RoundedRectangle(cornerRadius: ui(14), style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: ui(14), style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
