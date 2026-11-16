import Foundation
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Installed by `scripts/install.sh`: in /Applications, or in ~/Applications without admin rights.
    static var isInstalled: Bool {
        ["/Applications/Kerf.app", NSHomeDirectory() + "/Applications/Kerf.app"].contains(Bundle.main.bundlePath)
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Kerf: login item: \(error.localizedDescription)")
        }
    }

    /// Kerf opens at login by default. Only when installed, so a debug build never registers.
    static func registerOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Preferences.didRegisterLoginItem),
              isInstalled else { return }
        set(true)
        defaults.set(true, forKey: Preferences.didRegisterLoginItem)
    }
}
