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
}

/// The colours and glyphs of the app's fields (BUILD-BRIEF §1, §3), for the last known room word.
private extension RoomState {
    var field: Color {
        switch self {
        case .calm: Color(red: 0x00 / 255, green: 0xA1 / 255, blue: 0xA0 / 255)
        case .sound: Color(red: 0xFB / 255, green: 0xC0 / 255, blue: 0x40 / 255)
        case .cry: Color(red: 0xA8 / 255, green: 0x12 / 255, blue: 0x33 / 255)
        case .lost, .connecting: Color(red: 0x3A / 255, green: 0x3D / 255, blue: 0x45 / 255)
        }
    }
    /// The glyph on the field: white, ink on amber, red for a loss.
    var ink: Color {
        switch self {
        case .sound: Color(red: 0x1B / 255, green: 0x1B / 255, blue: 0x1F / 255)
        case .lost: alarm
        default: .white
        }
    }
    /// The accent on the dark island: the field colour, but a light glyph where graphite would vanish.
    var accent: Color {
        switch self {
        case .lost: alarm
        case .connecting: .white.opacity(0.8)
        default: field
        }
    }
    var symbol: String {
        switch self {
        case .connecting: "antenna.radiowaves.left.and.right"
        case .calm: "moon.zzz.fill"
        case .sound, .cry: "waveform"
        case .lost: "wifi.exclamationmark"
        }
    }
}

/// The time since the start, counting by itself: true with no update from the app.
private struct Elapsed: View {
    let started: Date
    var body: some View {
        Text(timerInterval: started...started.addingTimeInterval(24 * 3600), countsDown: false)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
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
            let room = context.state.state
            let started = context.attributes.started
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Chůvička", systemImage: "moon.stars.fill")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(moon)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("od \(started.formatted(.dateTime.hour().minute().locale(Locale(identifier: "cs_CZ"))))")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label("Upozorní na pláč i výpadek", systemImage: room.symbol)
                            .foregroundStyle(room.accent)
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
                Image(systemName: room.symbol).foregroundStyle(room.accent)
            } compactTrailing: {
                Elapsed(started: started)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(moon)
                    .frame(maxWidth: 56)
            } minimal: {
                Image(systemName: room.symbol).foregroundStyle(room.accent)
            }
            .keylineTint(room.accent)
        }
    }
}

private struct LockScreenView: View {
    let state: NurseryActivityAttributes.ContentState
    let started: Date

    var body: some View {
        let status = state.status
        let room = state.state
        HStack(spacing: 14) {
            // The last known room word as a colour, with no word: the app cannot keep it true
            // in the background. A cry is the white disc with the waveform in the field colour.
            ZStack {
                Circle().fill(room == .cry ? Color.white : room.field)
                Image(systemName: room.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(room == .cry ? room.field : room.ink)
            }
            .frame(width: 46, height: 46)
            .overlay(Circle().strokeBorder(.white.opacity(room == .lost || room == .connecting ? 0.25 : 0), lineWidth: 1.5))

            VStack(alignment: .leading, spacing: 3) {
                Text("Chůvička hlídá")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)
                // The status only when it is bad news that was true when the app last ran.
                Text(status.hearsRoom ? "Upozorní na pláč i výpadek" : status.title)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(status.hearsRoom ? .white.opacity(0.7) : status.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
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
