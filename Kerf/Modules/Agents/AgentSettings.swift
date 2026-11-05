import KerfKit
import SwiftUI

/// Connects Claude Code, Codex and Copilot: shows exactly what changes in their config, keeps a
/// backup, and only then writes. Apps that run these agents (T3 Code, an editor) come along.
struct AgentSettings: View {
    @AppStorage(AgentCenter.showsDoneKey) private var showsDone = true
    @AppStorage(AgentCenter.soundsDoneKey) private var soundsDone = true
    @AppStorage(AgentCenter.asksInFrontAppKey) private var asksInFrontApp = true
    @AppStorage(Preferences.playsSounds) private var playsSounds = true
    @State private var change: HookChange?
    @State private var refresh = 0
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                ForEach(HookTarget.allCases) { target in
                    LabeledContent {
                        if target.isInstalled {
                            HStack {
                                if !target.isCurrent {
                                    Button("Update…") { prepare(target, install: true) }
                                }
                                Button("Disconnect") { prepare(target, install: false) }
                            }
                        } else {
                            Button("Connect…") { prepare(target, install: true) }
                        }
                    } label: {
                        Text(target.name)
                        if target.isInstalled, !target.isCurrent {
                            Text("Connected, with older hooks")
                        } else {
                            Text(target.isInstalled ? "Connected" : "Not connected")
                        }
                    }
                }
            } header: {
                Text("Questions from coding agents")
            } footer: {
                Text("Kerf asks you in the notch and passes your answer back. If Kerf isn't running, the tool asks as it always does.")
                Text("Copilot permissions stay in Copilot or VS Code, respecting its approval settings. Kerf still shows its sessions and waiting questions.")
            }
            .id(refresh)

            Section("Other tools") {
                Text("Any tool or script can use the kerf command:")
                Text(verbatim: "\"\(HookInstaller.commandPath)\" notify --agent Gemini \"Done\"")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Text(verbatim: "\"\(HookInstaller.commandPath)\" notify --ask --agent Gemini \"Push to main?\"")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }

            Section {
                Toggle("Ask in the agent's own app while you're in it", isOn: $asksInFrontApp)
            } footer: {
                Text("A question or permission then shows in Claude, the terminal or the editor itself, and moves there when you switch to it. Kerf shows the orange dot.")
            }

            Section {
                Toggle("Show when an agent is done", isOn: $showsDone)
                Toggle("Play a sound when an agent is done", isOn: $soundsDone)
                    .disabled(!showsDone || !playsSounds)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $change) { change in
            DiffSheet(change: change) {
                do {
                    try change.apply()
                    refresh += 1
                    AgentCenter.shared.checkConnections()
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
        .alert("Couldn't change the file", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(verbatim: error ?? "")
        }
    }

    private func prepare(_ target: HookTarget, install: Bool) {
        do {
            change = try HookChange(target: target, install: install)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

enum HookTarget: String, CaseIterable, Identifiable {
    case claudeCode, codex, copilot

    var id: String { rawValue }

    var agent: AgentKind {
        switch self {
        case .claudeCode: .claudeCode
        case .codex: .codex
        case .copilot: .copilot
        }
    }

    var name: String { agent.displayName }

    var file: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return switch self {
        case .claudeCode: home.appendingPathComponent(".claude/settings.json")
        case .codex: home.appendingPathComponent(".codex/hooks.json")
        // Copilot reads every file in this folder: Kerf's own, so Copilot's stay untouched.
        case .copilot: home.appendingPathComponent(".copilot/hooks/kerf.json")
        }
    }

    var isInstalled: Bool {
        let text = try? String(contentsOf: file, encoding: .utf8)
        return self == .copilot ? HookInstaller.isCopilotFile(text) : HookInstaller.isInstalled(in: text, agent: agent)
    }

    /// Installed with the hooks this version wants. Copilot's file is Kerf's own and rewritten whole.
    var isCurrent: Bool {
        let text = try? String(contentsOf: file, encoding: .utf8)
        return self == .copilot ? text == HookInstaller.copilotFile() : HookInstaller.isCurrent(in: text, agent: agent)
    }
}

struct HookChange: Identifiable {
    let id = UUID()
    let target: HookTarget
    let install: Bool
    let old: String?
    /// Nil removes the file: Copilot's is Kerf's own.
    let new: String?

    init(target: HookTarget, install: Bool) throws {
        self.target = target
        self.install = install
        old = try? String(contentsOf: target.file, encoding: .utf8)
        if target == .copilot {
            new = install ? HookInstaller.copilotFile() : nil
        } else {
            new = install ? try HookInstaller.install(into: old, agent: target.agent) : try HookInstaller.remove(from: old ?? "{}", agent: target.agent)
        }
    }

    var diff: [String] { LineDiff.lines(from: old ?? "", to: new ?? "") }

    /// Backup first, then the new file in one go.
    func apply() throws {
        let files = FileManager.default
        guard let new else {
            try? files.removeItem(at: target.file)
            return
        }
        try files.createDirectory(at: target.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if files.fileExists(atPath: target.file.path) {
            let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
            let backup = target.file.deletingLastPathComponent().appendingPathComponent("\(target.file.lastPathComponent).kerf-backup-\(stamp)")
            try? files.removeItem(at: backup)
            try files.copyItem(at: target.file, to: backup)
        }
        try new.write(to: target.file, atomically: true, encoding: .utf8)
    }
}

struct DiffSheet: View {
    let change: HookChange
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(change.install ? "Connect \(change.target.name)" : "Disconnect \(change.target.name)").font(.headline)
            Text("These lines change in \(change.target.file.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")). A backup goes next to it.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(change.diff.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("+") ? Color.green : line.hasPrefix("-") ? Color.red : Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(height: 260)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            if change.install, change.target == .codex {
                Text("Then open Codex and type /hooks to trust Kerf's hooks.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(change.install ? "Connect" : "Disconnect") {
                    confirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
