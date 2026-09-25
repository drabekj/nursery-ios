import ActivityKit
import SwiftUI
import WidgetKit

@main
struct NurseryWidgetBundle: WidgetBundle {
    var body: some Widget {
        NurseryLiveActivity()
    }
}

private let moon = Color(red: 0.97, green: 0.85, blue: 0.55)
private let calm = Color(red: 0.45, green: 0.89, blue: 0.72)
private let warn = Color(red: 1.0, green: 0.72, blue: 0.38)
private let alarm = Color(red: 1.0, green: 0.42, blue: 0.42)

private extension NurseryActivityAttributes.Status {
    var color: Color {
        switch self {
        case .listening: calm
        case .silent: moon
        case .connecting: warn
        case .lost: alarm
        case .muted: .gray
        }
    }
    var hearsRoom: Bool { self == .listening || self == .silent }
    var symbol: String {
        switch self {
        case .listening: "ear.fill"
        case .silent: "bell.badge.fill"
        case .connecting: "antenna.radiowaves.left.and.right"
        case .lost: "exclamationmark.triangle.fill"
        case .muted: "speaker.slash.fill"
        }
    }
}

/// Five bars. They show the loudness of the room.
private struct LevelBars: View {
    let level: Int
    let color: Color
    var height: CGFloat = 18

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(i <= level ? color : color.opacity(0.25))
                    .frame(width: 3.5, height: height * (0.35 + 0.13 * CGFloat(i)))
            }
        }
        .frame(height: height)
    }
}

struct NurseryLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NurseryActivityAttributes.self) { context in
            LockScreenView(state: context.state, stale: context.isStale)
                .environment(\.locale, Locale(identifier: "cs_CZ"))
                .activityBackgroundTint(Color(red: 0.05, green: 0.07, blue: 0.15).opacity(0.92))
                .activitySystemActionForegroundColor(moon)
        } dynamicIsland: { context in
            let status = context.isStale ? .lost : context.state.status
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Chůvička", systemImage: "moon.stars.fill")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(moon)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LevelBars(level: status.hearsRoom ? context.state.level : -1, color: status.color, height: 22)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label(context.isStale ? "Aplikace neběží" : status.title, systemImage: status.symbol)
                            .foregroundStyle(status.color)
                        Spacer()
                        Text(context.state.since, style: .relative)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.system(.subheadline, design: .rounded))
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: status.symbol).foregroundStyle(status.color)
            } compactTrailing: {
                LevelBars(level: status.hearsRoom ? context.state.level : -1, color: status.color, height: 14)
            } minimal: {
                Image(systemName: status.symbol).foregroundStyle(status.color)
            }
            .keylineTint(status.color)
        }
    }
}

private struct LockScreenView: View {
    let state: NurseryActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        let status = stale ? NurseryActivityAttributes.Status.lost : state.status
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(status.color.opacity(0.18))
                Image(systemName: status.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(status.color)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text("Chůvička")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)
                Text(stale ? "Aplikace neběží. Otevřete ji znovu." : status.title)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(status.hearsRoom ? .white.opacity(0.7) : status.color)
            }
            Spacer()
            if status.hearsRoom {
                LevelBars(level: state.level, color: status.color, height: 26)
            } else {
                Text(state.since, style: .timer)
                    .font(.system(.subheadline, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 70)
            }
        }
        .padding(16)
    }
}
