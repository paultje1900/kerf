import KerfKit
import SwiftUI

enum UsageSide: String, CaseIterable, Identifiable {
    case left, right

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .left: "Left of the notch"
        case .right: "Right of the notch"
        }
    }
}

/// The usage rings beside the notch: on which side, and how many, which gives their width.
struct UsageStrip: Equatable {
    var side: UsageSide
    var count: Int

    static let ring: CGFloat = 20
    static let gap: CGFloat = 6
    /// The rings and 8 pt on each end.
    var width: CGFloat { CGFloat(count) * Self.ring + CGFloat(max(count - 1, 0)) * Self.gap + 16 }
}

/// 5 hours, week, model: always in that order, from orange to yellow, with how much of it is used.
/// The yellow one ends up beside the right wing, where the orange dot waits.
struct UsageRings: View {
    /// Halfway between the system's orange and yellow.
    private static let amber = Color(.sRGB, red: 1, green: 0.73, blue: 0.04)

    var body: some View {
        let usage = ClaudeUsageModule.shared.usage
        HStack(spacing: UsageStrip.gap) {
            if let session = usage?.session { UsageRing(limit: session, tint: Color(nsColor: .systemOrange), name: Text("5-hour session")) }
            if let week = usage?.week { UsageRing(limit: week, tint: Self.amber, name: Text("Week")) }
            if let model = usage?.model {
                UsageRing(limit: model, tint: Color(nsColor: .systemYellow),
                          name: usage?.modelName.map { Text("Week, \($0)") } ?? Text("Week, one model"))
            }
        }
    }
}

/// A ring that fills, on a dim track of its own colour, with the number small in the middle in that colour.
struct UsageRing: View {
    let limit: ClaudeUsage.Limit
    let tint: Color
    let name: Text
    private static let line: CGFloat = 2.2

    var body: some View {
        let percent = limit.percent(at: .now).rounded()
        ZStack {
            Circle().stroke(tint.opacity(0.28), lineWidth: Self.line)
            Circle().trim(from: 0, to: percent / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(verbatim: "\(Int(percent))")
                .font(.system(size: 8.5, weight: .medium).monospacedDigit().width(.condensed))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.numericText())
                .padding(.horizontal, 2.5)
        }
        // The stroke is drawn around the path: half of it would fall outside the frame.
        .padding(Self.line / 2)
        .frame(width: UsageStrip.ring, height: UsageStrip.ring)
        .animation(.smooth(duration: 0.4), value: percent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(Text("\(Int(percent)) percent used"))
    }
}
