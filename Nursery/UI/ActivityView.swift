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
                        Text("Graf se začne plnit, jakmile Chůvička poslouchá.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        chart.frame(height: 150).padding(.vertical, 6)
                    }
                } header: {
                    Text("Poslední hodina")
                } footer: {
                    Text("Čárkovaná čára značí citlivost. Zvuk nad ní, který trvá aspoň 1 sekundu, se zaznamená jako událost.")
                }

                Section("Dnes") {
                    if let now = activity.current {
                        EventRow(event: now, live: true)
                    }
                    let events = activity.todayEvents.reversed()
                    if events.isEmpty && activity.current == nil {
                        ContentUnavailableView {
                            Label("Klidný den", systemImage: "moon.zzz.fill")
                        } description: {
                            Text("Zvuky se tu objeví, když je zapnutý zvuk.")
                        }
                    } else {
                        ForEach(Array(events)) { EventRow(event: $0, live: false) }
                    }
                }

                Section {
                    Picker("Citlivost", selection: $settings.sensitivity) {
                        ForEach(Settings.Sensitivity.allCases) { Text($0.title).tag($0) }
                    }
                    Button("Smazat historii", role: .destructive) { confirmClear = true }
                        .disabled(activity.events.isEmpty)
                }
            }
            .navigationTitle("Aktivita")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Hotovo") { dismiss() } }
            }
            .confirmationDialog("Smazat historii zvuků?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Smazat historii", role: .destructive) { activity.clear() }
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(activity.minutes) { m in
                BarMark(x: .value("Čas", m.start, unit: .minute), y: .value("Hlasitost", m.peak))
                    .foregroundStyle(Theme.level(m.peak).gradient)
                    .cornerRadius(2)
            }
            RuleMark(y: .value("Citlivost", activity.threshold))
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
        .accessibilityLabel("Hlasitost za poslední hodinu")
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
                Text(live ? "Ozývá se" : duration).font(.subheadline).foregroundStyle(.secondary)
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

/// The last hour at a glance, on the main screen. It fills the space under the room panel
/// with the answer to "was it quiet?", and a tap opens the full Activity.
struct HourStrip: View {
    @ObservedObject var activity: SoundActivity
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Poslední hodina").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(summary).font(.footnote).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                if activity.minutes.isEmpty {
                    Text("Plní se, jakmile Chůvička poslouchá")
                        .font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    Chart {
                        ForEach(activity.minutes) { m in
                            BarMark(x: .value("Čas", m.start, unit: .minute), y: .value("Hlasitost", max(m.peak, 0.04)))
                                .foregroundStyle(Theme.level(m.peak).opacity(m.peak >= activity.threshold ? 1 : 0.55))
                                .cornerRadius(1.5)
                        }
                    }
                    .chartYScale(domain: 0...1)
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: 44)
                    HStack {
                        Text("před hodinou")
                        Spacer()
                        Text("teď")
                    }
                    .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(16)
            .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous), interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Poslední hodina. \(summary)")
        .accessibilityHint("Otevře přehled zvuků")
    }

    private var summary: String {
        let hour = activity.events.filter { $0.end > Date().addingTimeInterval(-3600) }
        // Czech plural: 1 zvuk, 2–4 zvuky, 5 a více zvuků.
        switch hour.count {
        case 0: return activity.current == nil ? "Bez zvuků" : "Ozývá se"
        case 1: return "1 zvuk"
        case 2...4: return "\(hour.count) zvuky"
        default: return "\(hour.count) zvuků"
        }
    }
}
