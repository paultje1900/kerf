import SwiftUI

enum SettingsTab: Hashable {
    case general, agents, features, pages, offload
}

struct SettingsView: View {
    @Bindable private var opener = SettingsOpener.shared

    var body: some View {
        TabView(selection: $opener.tab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) { GeneralSettings() }
            if Feature.agents.isOn {
                Tab("Agents", systemImage: "sparkles", value: SettingsTab.agents) { AgentSettings() }
            }
            Tab("Features", systemImage: "switch.2", value: SettingsTab.features) { FeatureSettings() }
            Tab("Pages", systemImage: "square.grid.2x2", value: SettingsTab.pages) { PageSettings() }
            if Feature.offload.isOn {
                Tab("Offload", systemImage: "sdcard", value: SettingsTab.offload) { OffloadSettings() }
            }
        }
        .frame(width: 560)
        .scenePadding()
    }
}

/// Opens Settings on a tab from anywhere. SwiftUI only opens its Settings window from a view, so
/// every island hosts a `SettingsOpenerHost` that does it.
@Observable
final class SettingsOpener {
    static let shared = SettingsOpener()

    var tab = SettingsTab.general
    fileprivate var requests = 0
    fileprivate var handled = 0

    static func open(tab: SettingsTab) {
        shared.tab = tab
        shared.requests += 1
        // No island on screen to do it (all hidden for full screen): the app menu's Settings item.
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            guard shared.handled < shared.requests else { return }
            shared.handled = shared.requests
            NSApp.activate()
            if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }), let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            }
        }
    }
}

struct SettingsOpenerHost: View {
    @Environment(\.openSettings) private var openSettings
    private let opener = SettingsOpener.shared

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .task(id: opener.requests) {
                // One island opens it, however many there are.
                guard opener.requests > opener.handled else { return }
                opener.handled = opener.requests
                NSApp.activate()
                openSettings()
            }
    }
}

struct GeneralSettings: View {
    @AppStorage(Preferences.showOnExternalDisplays) private var showOnExternalDisplays = false
    @AppStorage(Preferences.hoverOpenDelay) private var hoverOpenDelay = 0.25
    @AppStorage(Preferences.playsSounds) private var playsSounds = true
    @AppStorage(Preferences.closesOnLeave) private var closesOnLeave = true
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Toggle("Open at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in LoginItem.set(on) }
            Toggle("Show on displays without a notch", isOn: $showOnExternalDisplays)
            Toggle(isOn: $closesOnLeave) {
                Text("Close when the pointer leaves")
                Text("Off: the island stays open until you press Escape or click the notch.")
            }
            LabeledContent("Open after hovering") {
                Picker("Open after hovering", selection: $hoverOpenDelay) {
                    Text("0.25 seconds").tag(0.25)
                    Text("0.5 seconds").tag(0.5)
                    Text("1 second").tag(1.0)
                    Text("1.5 seconds").tag(1.5)
                }
                .labelsHidden()
                .fixedSize()
            }
            Toggle("Play sounds", isOn: $playsSounds)
            AccessibilitySetting()
            LabeledContent("Open the island", value: "⌥ Space")
            if Feature.ask.isOn {
                LabeledContent("Ask Claude about the selection", value: "⌥⇧ Space")
            }
        }
        .formStyle(.grouped)
    }
}

/// Escape from any app, volume and brightness in the notch, and the selected text for Ask.
struct AccessibilitySetting: View {
    @State private var trusted = SelectionReader.isTrusted

    var body: some View {
        if !trusted {
            LabeledContent {
                Button("Allow Accessibility…") {
                    SelectionReader.requestTrust()
                    Task {
                        // Picked up once the switch in System Settings is on.
                        for _ in 0..<60 {
                            try? await Task.sleep(for: .seconds(2))
                            if SelectionReader.isTrusted {
                                trusted = true
                                MediaKeys.shared.start()
                                return
                            }
                        }
                    }
                }
            } label: {
                Text("Accessibility")
                Text("Lets Escape close the island from any app, shows volume and brightness in the notch, and reads the selected text for Ask.")
            }
        }
    }
}

/// Everything Kerf can do, each on its own switch. What's off doesn't run at all.
struct FeatureSettings: View {
    var body: some View {
        Form {
            ForEach(Feature.Group.allCases) { group in
                Section {
                    ForEach(group.features) { FeatureToggle(feature: $0) }
                } header: {
                    Text(group.title)
                } footer: {
                    if group == .coding {
                        Text("Kerf is the notch for your coding agents first. Switch on whatever else you want; what's off doesn't run.")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct FeatureToggle: View {
    let feature: Feature

    var body: some View {
        Toggle(isOn: Binding(get: { feature.isOn }, set: { feature.set($0) })) {
            Text(feature.title)
            Text(feature.summary)
        }
    }
}

/// The pages of what's switched on: each on or off, and in the bar or under "…".
struct PageSettings: View {
    var body: some View {
        Form {
            Section {
                ForEach(IslandPage.placeable.filter(\.isAvailable)) { PageRow(page: $0) }
            } header: {
                Text("Pages")
            } footer: {
                Text("Four icons fit on each side of the notch. The rest goes under …")
                Text("Switch on more in Features. Overview needs Now Playing and Calendar.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct PageRow: View {
    let page: IslandPage
    @AppStorage private var placement: PagePlacement

    init(page: IslandPage) {
        self.page = page
        _placement = AppStorage(wrappedValue: .bar, page.placementKey)
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 12) {
                if placement != .off {
                    Picker("Place", selection: Binding(get: { placement }, set: { place($0) })) {
                        Text(PagePlacement.bar.title).tag(PagePlacement.bar)
                        Text(PagePlacement.more.title).tag(PagePlacement.more)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Toggle("Show", isOn: Binding(get: { placement != .off }, set: { place($0 ? .bar : .off) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        } label: {
            Label { Text(page.title) } icon: { Image(systemName: page.symbol) }
        }
    }

    private func place(_ new: PagePlacement) {
        placement = new
        Hub.shared.refresh()
    }
}
