import Charts
import SwiftUI

/// "Did the baby make a sound while I was away?" The last hour as a chart, and the events of today.
struct ActivityView: View {
    @ObservedObject var activity: SoundActivity
    @EnvironmentObject private var settings: Settings
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if activity.minutes.isEmpty {
                        Text("The chart fills while Nursery listens.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        chart.frame(height: 150).padding(.vertical, 6)
                    }
                } header: {
                    Text("Last hour")
                } footer: {
                    Text("The dashed line is the sensitivity. A sound above it for 1 second counts as a sound event.")
                }

                Section("Today") {
                    if let now = activity.current {
                        EventRow(event: now, live: true)
                    }
                    let events = activity.todayEvents.reversed()
                    if events.isEmpty && activity.current == nil {
                        ContentUnavailableView {
                            Label("A quiet day", systemImage: "moon.zzz.fill")
                        } description: {
                            Text("Sound events appear here while the sound is on.")
                        }
                    } else {
                        ForEach(Array(events)) { EventRow(event: $0, live: false) }
                    }
                }

                Section {
                    Picker("Sensitivity", selection: $settings.sensitivity) {
                        ForEach(Settings.Sensitivity.allCases) { Text($0.title).tag($0) }
                    }
                    Button("Clear History", role: .destructive) { confirmClear = true }
                        .disabled(activity.events.isEmpty)
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Clear the sound history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) { activity.clear() }
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(activity.minutes) { m in
                BarMark(x: .value("Time", m.start, unit: .minute), y: .value("Loudness", m.peak))
                    .foregroundStyle(Theme.level(m.peak).gradient)
                    .cornerRadius(2)
            }
            RuleMark(y: .value("Sensitivity", activity.threshold))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(.secondary)
        }
        .chartYScale(domain: 0...1)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute, count: 15)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .accessibilityLabel("Loudness in the last hour")
    }
}

private struct EventRow: View {
    let event: SoundActivity.Event
    let live: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: live ? "waveform" : "waveform.path")
                .font(.title3)
                .foregroundStyle(Theme.level(event.peak))
                .symbolEffect(.variableColor.iterative, isActive: live)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.start, style: .time).font(.headline).monospacedDigit()
                Text(live ? "Sound now" : duration).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Waveform.word(for: event.peak))
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.level(event.peak).opacity(0.18), in: Capsule())
                .foregroundStyle(Theme.level(event.peak))
        }
        .accessibilityElement(children: .combine)
    }

    private var duration: String {
        let s = Int(event.duration.rounded())
        return s < 60 ? "\(max(s, 1)) s" : "\(s / 60) min \(s % 60) s"
    }
}
