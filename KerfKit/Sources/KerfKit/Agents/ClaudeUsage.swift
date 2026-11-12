import Foundation

/// How much of a Claude plan's limits is used, as Claude Code's own /usage reports it: the
/// 5-hour session, the week, and the week for one model (Fable) where the plan has such a limit.
public struct ClaudeUsage: Equatable, Sendable {
    public struct Limit: Equatable, Sendable {
        /// 0 to 100.
        public var percent: Double
        public var resetsAt: Date?

        public init(percent: Double, resetsAt: Date? = nil) {
            self.percent = percent
            self.resetsAt = resetsAt
        }

        /// A window that reset since the answer starts empty again.
        public func percent(at now: Date) -> Double {
            if let resetsAt, resetsAt <= now { return 0 }
            return min(max(percent, 0), 100)
        }
    }

    public var session: Limit?
    public var week: Limit?
    /// The week for one model, with the name Claude gives it.
    public var model: Limit?
    public var modelName: String?
    /// False when the answer left the per-model limits out (it does when it comes from its cache).
    public var knowsModels = true

    public init(session: Limit? = nil, week: Limit? = nil, model: Limit? = nil, modelName: String? = nil) {
        self.session = session
        self.week = week
        self.model = model
        self.modelName = modelName
    }

    /// The limits in the order they show: 5 hours, week, model.
    public var limits: [Limit] { [session, week, model].compactMap { $0 } }

    /// The soonest moment a limit starts over, after `now`.
    public func nextReset(after now: Date) -> Date? {
        limits.compactMap(\.resetsAt).filter { $0 > now }.min()
    }

    /// An answer without per-model limits keeps the ones known before.
    public func keepingModel(from previous: ClaudeUsage?) -> ClaudeUsage {
        guard !knowsModels, let previous else { return self }
        var usage = self
        usage.model = previous.model
        usage.modelName = previous.modelName
        return usage
    }

    public static let requestID = "kerf-usage"

    /// What to send `claude -p --input-format stream-json`: asks for the plan's limits, without
    /// a prompt and without the scan of transcripts that /usage also does.
    public static let request = #"{"type":"control_request","request_id":"\#(requestID)","request":{"subtype":"get_usage","skip_behaviors":true}}"#

    public enum Answer: Equatable, Sendable {
        case limits(ClaudeUsage)
        /// Claude Code answered, but this account has no plan limits (an API key) or couldn't say.
        case unavailable
    }

    /// One line of Claude Code's output; nil unless it answers `request`.
    public static func answer(in line: Data) -> Answer? {
        guard let json = JSONValue.parse(line), json["type"]?.string == "control_response", let response = json["response"],
              response["request_id"]?.string == requestID else { return nil }
        guard response["subtype"]?.string == "success", let limits = response["response"]?["rate_limits"], limits.object != nil else {
            return .unavailable
        }
        var usage = ClaudeUsage(session: limit(limits["five_hour"], percent: "utilization"), week: limit(limits["seven_day"], percent: "utilization"))
        // The model limit closest to full: the one that stops you first.
        let models = limits["model_scoped"]?.array
        usage.knowsModels = models != nil
        let fullest = (models ?? []).compactMap { entry in limit(entry, percent: "utilization").map { (entry["display_name"]?.string, $0) } }
            .max { $0.1.percent < $1.1.percent }
        usage.model = fullest?.1
        usage.modelName = fullest?.0
        return usage.limits.isEmpty ? .unavailable : .limits(usage)
    }

    private static func limit(_ value: JSONValue?, percent key: String) -> Limit? {
        guard let percent = value?[key]?.number else { return nil }
        return Limit(percent: percent, resetsAt: value?["resets_at"]?.string.flatMap(date))
    }

    /// "2026-11-13T03:10:00.250144+00:00", with or without the fraction.
    private static func date(_ text: String) -> Date? {
        (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: .iso8601))
    }
}
