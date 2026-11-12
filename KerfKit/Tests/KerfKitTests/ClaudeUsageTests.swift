import Foundation
import Testing
@testable import KerfKit

struct ClaudeUsageTests {
    /// What Claude Code 2.1.309 answers, shortened.
    private static let answer = #"""
    {"type":"control_response","response":{"subtype":"success","request_id":"kerf-usage","response":{"subscription_type":"pro","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":28,"resets_at":"2026-11-13T03:10:00.250144+00:00"},"seven_day":{"utilization":60,"resets_at":"2026-11-16T04:00:00.250164+00:00"},"seven_day_opus":null,"model_scoped":[{"display_name":"Fable","utilization":79,"resets_at":"2026-11-16T04:00:00.250305+00:00"}],"extra_usage":{"is_enabled":false}},"behaviors":null}}}
    """#

    private func usage(_ text: String) -> ClaudeUsage? {
        if case .limits(let usage) = ClaudeUsage.answer(in: Data(text.utf8)) { usage } else { nil }
    }

    @Test func readsTheThreeLimits() throws {
        let usage = try #require(usage(Self.answer))
        #expect(usage.session?.percent == 28)
        #expect(usage.week?.percent == 60)
        #expect(usage.model?.percent == 79)
        #expect(usage.modelName == "Fable")
        #expect(usage.limits.map(\.percent) == [28, 60, 79])
        let reset = try #require(usage.session?.resetsAt)
        #expect(abs(reset.timeIntervalSince1970 - 1_794_539_400.25) < 0.01)
    }

    @Test func aPlanWithoutModelLimitHasTwo() throws {
        let text = Self.answer.replacingOccurrences(of: #""model_scoped":[{"display_name":"Fable","utilization":79,"resets_at":"2026-11-16T04:00:00.250305+00:00"}]"#, with: #""model_scoped":[]"#)
        let usage = try #require(usage(text))
        #expect(usage.model == nil)
        #expect(usage.knowsModels)
        #expect(usage.limits.count == 2)
    }

    @Test func anAnswerFromTheCacheKeepsTheModelLimit() throws {
        let before = try #require(usage(Self.answer))
        let text = Self.answer.replacingOccurrences(of: #""model_scoped":[{"display_name":"Fable","utilization":79,"resets_at":"2026-11-16T04:00:00.250305+00:00"}],"#, with: "")
        let cached = try #require(usage(text))
        #expect(!cached.knowsModels)
        #expect(cached.model == nil)
        #expect(cached.keepingModel(from: before).model?.percent == 79)
        #expect(cached.keepingModel(from: before).modelName == "Fable")
        #expect(before.keepingModel(from: nil) == before)
    }

    @Test func theFullestModelLimitShows() throws {
        let text = Self.answer.replacingOccurrences(of: #"[{"display_name":"Fable""#, with: #"[{"display_name":"Opus","utilization":12,"resets_at":null},{"display_name":"Fable""#)
        let usage = try #require(usage(text))
        #expect(usage.modelName == "Fable")
        #expect(usage.model?.percent == 79)
    }

    @Test func otherLinesAndAccountsWithoutLimits() {
        #expect(ClaudeUsage.answer(in: Data(#"{"type":"system","subtype":"init","session_id":"s1"}"#.utf8)) == nil)
        #expect(ClaudeUsage.answer(in: Data("nonsense".utf8)) == nil)
        #expect(ClaudeUsage.answer(in: Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"other","response":{}}}"#.utf8)) == nil)
        // An API key: no plan, no limits.
        #expect(ClaudeUsage.answer(in: Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"kerf-usage","response":{"rate_limits_available":false,"rate_limits":null}}}"#.utf8)) == .unavailable)
        // An older Claude Code doesn't know the question.
        #expect(ClaudeUsage.answer(in: Data(#"{"type":"control_response","response":{"subtype":"error","request_id":"kerf-usage","error":"Unsupported control request subtype: get_usage"}}"#.utf8)) == .unavailable)
    }

    @Test func aWindowThatResetStartsEmpty() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(ClaudeUsage.Limit(percent: 80, resetsAt: now.addingTimeInterval(60)).percent(at: now) == 80)
        #expect(ClaudeUsage.Limit(percent: 80, resetsAt: now.addingTimeInterval(-60)).percent(at: now) == 0)
        #expect(ClaudeUsage.Limit(percent: 80).percent(at: now) == 80)
        #expect(ClaudeUsage.Limit(percent: 104).percent(at: now) == 100)
        let usage = ClaudeUsage(session: .init(percent: 10, resetsAt: now.addingTimeInterval(-5)), week: .init(percent: 20, resetsAt: now.addingTimeInterval(500)),
                                model: .init(percent: 30, resetsAt: now.addingTimeInterval(900)))
        #expect(usage.nextReset(after: now) == now.addingTimeInterval(500))
    }

    @Test func theRequestIsOneLineOfJSON() {
        let json = JSONValue.parse(Data(ClaudeUsage.request.utf8))
        #expect(json?["request"]?["subtype"]?.string == "get_usage")
        #expect(json?["request"]?["skip_behaviors"]?.bool == true)
        #expect(json?["request_id"]?.string == ClaudeUsage.requestID)
        #expect(!ClaudeUsage.request.contains("\n"))
    }
}
