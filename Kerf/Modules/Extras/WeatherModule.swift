import CoreLocation
import SwiftUI

/// The temperature and rain in the coming hours, from Open-Meteo (no account, no key), for
/// where the Mac is. Asks for location when Weather is switched on, or from the Today page.
@Observable
final class WeatherModule: NSObject, CLLocationManagerDelegate {
    static let shared = WeatherModule()

    struct Now: Equatable {
        var temperature: Double
        var symbol: String
        /// When rain starts in the next two hours, if it does.
        var rainAt: Date?
    }

    private(set) var now: Now?
    private(set) var authorization = CLLocationManager().authorizationStatus
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var location: CLLocation?

    var isAllowed: Bool { authorization == .authorizedAlways || authorization == .authorized }

    func start() {
        guard timer == nil else { return }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        if isAllowed { manager.requestLocation() }
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in
            Task { @MainActor in WeatherModule.shared.refresh() }
        }
        timer?.tolerance = 120
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        location = nil
        now = nil
    }

    func requestAccess() {
        manager.requestWhenInUseAuthorization()
    }

    func refresh() {
        guard isAllowed, Feature.weather.isOn else { return }
        if let location { Task { await fetch(location) } } else { manager.requestLocation() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            WeatherModule.shared.authorization = status
            WeatherModule.shared.refresh()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            guard Feature.weather.isOn else { return }
            WeatherModule.shared.location = location
            await WeatherModule.shared.fetch(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    private func fetch(_ location: CLLocation) async {
        let latitude = String(format: "%.3f", location.coordinate.latitude)
        let longitude = String(format: "%.3f", location.coordinate.longitude)
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&current=temperature_2m,weather_code,is_day&minutely_15=precipitation&forecast_minutely_15=8&timezone=UTC"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any],
              let temperature = current["temperature_2m"] as? Double else { return }
        let code = current["weather_code"] as? Int ?? 0
        let day = (current["is_day"] as? Int ?? 1) == 1
        var rainAt: Date?
        if let minutely = json["minutely_15"] as? [String: Any], let times = minutely["time"] as? [String], let rain = minutely["precipitation"] as? [Double] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
            for (time, amount) in zip(times, rain) where amount >= 0.1 {
                if let date = formatter.date(from: time + ":00Z") ?? formatter.date(from: time), date > .now.addingTimeInterval(-900) {
                    rainAt = date
                    break
                }
            }
        }
        now = Now(temperature: temperature, symbol: Self.symbol(code, day: day), rainAt: rainAt)
    }

    /// WMO weather codes → SF Symbols.
    static func symbol(_ code: Int, day: Bool) -> String {
        switch code {
        case 0: day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 61...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    /// Lab only.
    func preview(_ now: Now) {
        authorization = .authorized
        self.now = now
    }
}

/// The Focus that is on, if macOS lets Kerf read it (it needs Full Disk Access), and the way to
/// the Focus settings.
enum FocusStatus {
    static var current: String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = (json["data"] as? [[String: Any]])?.first?["storeAssertionRecords"] as? [[String: Any]],
              let mode = records.first?["assertionDetails"] as? [String: Any] else { return nil }
        let identifier = mode["assertionDetailsModeIdentifier"] as? String ?? ""
        if identifier.contains("sleep") { return String(localized: "Sleep") }
        if identifier.contains("work") { return String(localized: "Work") }
        if identifier.contains("personal") { return String(localized: "Personal") }
        if identifier.contains("driving") { return String(localized: "Driving") }
        return String(localized: "Do Not Disturb")
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}
