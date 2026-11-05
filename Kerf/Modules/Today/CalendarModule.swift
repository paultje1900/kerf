import AppKit
import EventKit
import KerfKit
import SwiftUI

/// Today's events from every calendar in the Calendar app, with their call links. They stay on
/// the Today page: no notifications in the notch.
@Observable
final class CalendarModule {
    static let shared = CalendarModule()

    struct Event: Equatable, Identifiable {
        var title: String
        var start: Date
        var end: Date
        var color: Color
        var location: String? = nil
        var joinURL: URL? = nil
        var id: String
    }

    /// Today's timed events, earliest first.
    private(set) var events: [Event] = []
    private(set) var access = EKEventStore.authorizationStatus(for: .event)
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var isPreview = false

    var hasAccess: Bool { access == .fullAccess }

    /// The event on now, or the first still to come.
    func next(at now: Date = .now) -> Event? {
        events.first { $0.end > now }
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { CalendarModule.shared.refresh() }
        }
        refresh()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        events = []
    }

    /// Asked when Calendar is switched on, or from the Today page.
    func requestAccess() {
        store.requestFullAccessToEvents { _, _ in
            Task { @MainActor in
                CalendarModule.shared.access = EKEventStore.authorizationStatus(for: .event)
                CalendarModule.shared.refresh()
            }
        }
    }

    /// Also when the Today page opens, so a new day starts with its own list.
    func refresh() {
        guard !isPreview, Feature.calendar.isOn else { return }
        access = EKEventStore.authorizationStatus(for: .event)
        guard hasAccess else { return }
        let day = Calendar.current.dateInterval(of: .day, for: .now) ?? DateInterval(start: .now, duration: 86_400)
        let predicate = store.predicateForEvents(withStart: day.start, end: day.end, calendars: nil)
        let found = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                Event(title: event.title ?? "", start: event.startDate, end: event.endDate,
                      color: Color(cgColor: event.calendar.cgColor), location: event.location,
                      joinURL: JoinLink.find(in: [event.url?.absoluteString, event.location, event.notes]),
                      id: event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? UUID().uuidString)
            }
        if found != events { events = found }
    }

    func join(_ event: Event) {
        if let url = event.joinURL { NSWorkspace.shared.open(url) }
    }

    func openInCalendar() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }

    /// Lab only.
    func preview(_ events: [Event]) {
        isPreview = true
        access = .fullAccess
        self.events = events
    }
}

extension CalendarModule.Event {
    /// "In 11 min · 18:10 – 18:40", "Now, until 18:40", or the times.
    func when(now: Date) -> String {
        let times = "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
        guard end > now else { return times }
        if start <= now { return String(localized: "Now, until \(end.formatted(date: .omitted, time: .shortened))") }
        let minutes = Int(start.timeIntervalSince(now) / 60)
        if minutes < 60 { return String(localized: "In \(minutes) min · \(times)") }
        return times
    }
}
