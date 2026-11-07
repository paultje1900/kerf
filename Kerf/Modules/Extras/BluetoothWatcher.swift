import CoreBluetooth
import IOBluetooth
import SwiftUI

/// AirPods and other headphones connecting, with their battery when the Mac knows it.
/// Only once AirPods is switched on and Bluetooth allowed.
final class IOBluetoothWatcher: NSObject {
    static let shared = IOBluetoothWatcher()
    private var notification: IOBluetoothUserNotification?
    private var askingManager: CBCentralManager?

    var isAllowed: Bool { CBCentralManager.authorization == .allowedAlways }

    func startIfAllowed() {
        guard isAllowed, notification == nil, Feature.airpods.isOn else { return }
        notification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
    }

    func stop() {
        notification?.unregister()
        notification = nil
    }

    /// Shows the system question; starts once allowed.
    func requestAccess() {
        askingManager = CBCentralManager(delegate: nil, queue: nil)
        Task {
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                if isAllowed {
                    startIfAllowed()
                    return
                }
            }
        }
    }

    /// IOBluetooth calls this on its own queue, for every device that connects: nonisolated, or Swift traps.
    @objc nonisolated private func connected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard device.deviceClassMajor == kBluetoothDeviceClassMajorAudio || (device.name ?? "").localizedCaseInsensitiveContains("airpods") else { return }
        nonisolated(unsafe) let device = device
        // A moment later the battery levels are known.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let name = device.name ?? "AirPods"
            let percent = Self.battery(of: device)
            let symbol = name.localizedCaseInsensitiveContains("max") ? "airpodsmax"
                : name.localizedCaseInsensitiveContains("pro") ? "airpodspro" : name.localizedCaseInsensitiveContains("airpods") ? "airpods" : "headphones"
            Hub.shared.flash(.banner(.symbol(symbol, .white), percent.map { .value("\($0)%") } ?? .symbol("checkmark", .white)), seconds: 3)
        }
    }

    /// The lowest bud, or the single battery: private but long-standing IOBluetooth properties.
    private static func battery(of device: IOBluetoothDevice) -> Int? {
        let keys = ["batteryPercentLeft", "batteryPercentRight", "batteryPercentSingle", "batteryPercentCombined"]
        let values = keys.compactMap { key -> Int? in
            guard device.responds(to: NSSelectorFromString(key)), let value = device.value(forKey: key) as? NSNumber else { return nil }
            let percent = value.intValue
            return percent > 0 ? percent : nil
        }
        return values.min()
    }
}
