import Foundation

/// UserDefaults keys, so @AppStorage and code read the same names.
enum Preferences {
    static let showOnExternalDisplays = "showOnExternalDisplays"
    static let hoverOpenDelay = "hoverOpenDelay"
    static let playsSounds = "playsSounds"
    static let didRegisterLoginItem = "didRegisterLoginItem"
    /// Set at the first launch, which opens Settings → Agents when no agent is connected yet.
    static let didLaunch = "didLaunch"
    /// On: the open island becomes small again when the pointer leaves it. Off: it stays until
    /// Escape, a click on the notch, or ⌥ Space.
    static let closesOnLeave = "closesOnLeave"
    /// The patch notes you've seen, by file name.
    static let seenNotes = "whatsNew.seen"
    /// Off: Kerf never runs git to look for a newer version.
    static let checksForUpdates = "checksForUpdates"
    /// When Update started the build, so the new Kerf can say it's done.
    static let updateStarted = "update.started"

    static func register() {
        UserDefaults.standard.register(defaults: [
            showOnExternalDisplays: false,
            hoverOpenDelay: 0.25,
            playsSounds: true,
            closesOnLeave: true,
            checksForUpdates: true,
        ])
    }
}
