import ActivityKit
import AppIntents
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
        }
    }
    var hearsRoom: Bool { self == .listening || self == .silent }
    var symbol: String {
        switch self {
        case .listening: "ear.fill"
        case .silent: "bell.badge.fill"
        case .connecting: "antenna.radiowaves.left.and.right"
        case .lost: "exclamationmark.triangle.fill"
        }
    }
}

struct NurseryLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NurseryActivityAttributes.self) { context in
            LockScreenView(state: context.state, started: context.attributes.started)
                .environment(\.locale, Locale(identifier: "cs_CZ"))
                .activityBackgroundTint(Color(red: 0.05, green: 0.07, blue: 0.15).opacity(0.92))
                .activitySystemActionForegroundColor(moon)
        } dynamicIsland: { context in
            let status = context.state.status
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Chůvička", systemImage: "moon.stars.fill")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(moon)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("od \(context.attributes.started.formatted(.dateTime.hour().minute().locale(Locale(identifier: "cs_CZ"))))")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label(status.title, systemImage: status.symbol)
                            .foregroundStyle(status.color)
                            .font(.system(.subheadline, design: .rounded))
                        Spacer()
                        Button(intent: StopMonitoringIntent()) {
                            Label("Ukončit hlídání", systemImage: "stop.fill").font(.system(.caption, design: .rounded).weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(moon)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: status.symbol).foregroundStyle(status.color)
            } compactTrailing: {
                Image(systemName: "moon.stars.fill").foregroundStyle(moon)
            } minimal: {
                Image(systemName: status.symbol).foregroundStyle(status.color)
            }
            .keylineTint(status.color)
        }
    }
}

private struct LockScreenView: View {
    let state: NurseryActivityAttributes.ContentState
    let started: Date

    var body: some View {
        let status = state.status
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(status.color.opacity(0.18))
                Image(systemName: status.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(status.color)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text("Chůvička hlídá")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)
                Text(status.title)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(status.hearsRoom ? .white.opacity(0.7) : status.color)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text("od \(started.formatted(.dateTime.hour().minute().locale(Locale(identifier: "cs_CZ"))))")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                // The clear way to stop, right where the parent sees that it runs.
                Button(intent: StopMonitoringIntent()) {
                    Label("Ukončit hlídání", systemImage: "stop.fill")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .tint(moon)
            }
        }
        .padding(16)
    }
}
