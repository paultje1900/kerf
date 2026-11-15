import SwiftUI

struct KerfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Kerf", systemImage: "capsule.tophalf.filled") {
            MenuBarMenu()
        }
        Settings {
            SettingsView()
        }
    }
}

struct MenuBarMenu: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Button("What's New in Kerf…") { WhatsNewWindow.show(.all, activate: true) }
        if Updater.shared.source != nil {
            Button("Check for Updates…") { Updater.shared.check(manual: true) }
        }
        Divider()
        Button("Quit Kerf") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
