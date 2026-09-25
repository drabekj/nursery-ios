import Charts
import SwiftUI

// "Přehled": what happened in the room while you were away, in one sentence, one timeline,
// and one row per episode with a photo of the moment.

private let cs = Locale(identifier: "cs_CZ")

private func timeText(_ d: Date) -> String { d.formatted(.dateTime.hour().minute().locale(cs)) }

private func durationText(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(max(s, 1)) s" }
    if s < 3600 { return "\(s / 60) min" }
    return "\(s / 3600) h \(s % 3600 / 60) min"
}

/// Czech plural: 1 událost, 2–4 události, 5 a více událostí.
private func eventsText(_ n: Int) -> String {
    switch n {
    case 1: return "1 událost"
    case 2...4: return "\(n) události"
    default: return "\(n) událostí"
    }
}

/// The one sentence at the top: what the parent wants to know first.
@MainActor
private struct Summary {
    let headline: String
    let detail: String

    init(activity: SoundActivity, since: Date) {
        let episodes = activity.episodes(since: since)
        let listened = activity.listened(since: since)
        let cries = episodes.filter { $0.kind == .cry }.count
        if listened < 60 {
            headline = "Zatím bez záznamu"
            detail = "Přehled se plní, když Chůvička poslouchá."
        } else if activity.current != nil {
            headline = "Právě se ozývá"
            detail = "Poslouchá \(durationText(listened))"
        } else if episodes.isEmpty {
            headline = "Klid"
            detail = "Poslouchala \(durationText(listened)) a nic neslyšela."
        } else {
            headline = cries > 0 ? (cries == 1 ? "1× pláč" : "\(cries)× pláč") : eventsText(episodes.count)
            let last = episodes[0]
            detail = "Naposledy v \(timeText(last.start)) (\(durationText(last.duration))) · poslouchala \(durationText(listened))"
        }
    }
}

struct ActivityView: View {
    @ObservedObject var activity: SoundActivity
    @EnvironmentObject private var settings: Settings
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false
    @State private var photo: PhotoItem?

    private var since: Date { Date().addingTimeInterval(-12 * 3600) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let s = Summary(activity: activity, since: since)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.headline).font(.system(.title, design: .rounded).weight(.semibold))
                        Text(s.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    Timeline(activity: activity, since: since, height: 56, hourLabels: true)
                        .padding(.vertical, 6)
                    Legend()
                } header: {
                    Text("Posledních 12 hodin")
                }

                Section {
                    let episodes = activity.episodes(since: since)
                    if episodes.isEmpty {
                        ContentUnavailableView {
                            Label("Žádné události", systemImage: "moon.zzz.fill")
                        } description: {
                            Text("Když se miminko ozve, objeví se tu čas, délka a fotka z kamery.")
                        }
                    } else {
                        ForEach(episodes) { e in
                            EpisodeRow(episode: e, live: activity.current != nil && e.id == episodes.first?.id) {
                                if let image = Moments.image(for: e.id) { photo = PhotoItem(image: image, episode: e) }
                            }
                        }
                    }
                } header: {
                    Text("Události")
                }

                Section {
                    Picker("Citlivost", selection: $settings.sensitivity) {
                        ForEach(Settings.Sensitivity.allCases) { Text($0.title).tag($0) }
                    }
                    Button("Smazat historii", role: .destructive) { confirmClear = true }
                        .disabled(activity.events.isEmpty && activity.coverage.isEmpty)
                } footer: {
                    Text("Chůvička se sama přizpůsobí šumu v pokoji, třeba ventilátoru nebo šumu kamery. Citlivost určuje, jak výrazný zvuk se zaznamená. Zvuky blíž než 90 sekund od sebe tvoří jednu událost.")
                }
            }
            .navigationTitle("Přehled")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Hotovo") { dismiss() } }
            }
            .confirmationDialog("Smazat historii a fotky?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Smazat historii", role: .destructive) { activity.clear() }
            }
            .sheet(item: $photo) { PhotoView(item: $0) }
        }
    }
}

/// The listening time as a light band, and each episode as a mark: amber for fussing, coral for crying.
/// A grey gap means that Chůvička did not listen then. That is not the same as quiet.
struct Timeline: View {
    @ObservedObject var activity: SoundActivity
    let since: Date
    var height: CGFloat = 40
    var hourLabels = false

    var body: some View {
        let now = Date()
        let spans = activity.coverage(since: since)
        let episodes = activity.episodes(since: since)
        let minWidth = now.timeIntervalSince(since) / 160      // An episode stays visible, also a short one.
        Chart {
            RectangleMark(xStart: .value("Od", since), xEnd: .value("Do", now), yStart: .value("y", 0.0), yEnd: .value("y", 1.0))
                .foregroundStyle(Color.secondary.opacity(0.12))
            ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                RectangleMark(xStart: .value("Od", span.start), xEnd: .value("Do", span.end), yStart: .value("y", 0.0), yEnd: .value("y", 1.0))
                    .foregroundStyle(Theme.calm.opacity(0.28))
            }
            ForEach(episodes) { e in
                RectangleMark(xStart: .value("Od", e.start),
                              xEnd: .value("Do", max(e.end, e.start.addingTimeInterval(minWidth))),
                              yStart: .value("y", 0.0), yEnd: .value("y", 1.0))
                    .foregroundStyle(e.kind == .cry ? Theme.loud : Theme.middle)
            }
        }
        .chartXScale(domain: since...now)
        .chartYScale(domain: 0.0...1.0)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .stride(by: .hour, count: 3)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartXAxis(hourLabels ? .visible : .hidden)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .environment(\.locale, cs)
        .accessibilityElement()
        .accessibilityLabel(Summary(activity: activity, since: since).headline)
    }
}

private struct Legend: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                item(Theme.middle, "Zafňukání")
                item(Theme.loud, "Pláč")
            }
            GridRow {
                item(Theme.calm.opacity(0.5), "Poslouchala")
                item(Color.secondary.opacity(0.25), "Neposlouchala")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func item(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 8)
            Text(title).lineLimit(1)
        }
    }
}

private struct EpisodeRow: View {
    let episode: SoundActivity.Episode
    let live: Bool
    let showPhoto: () -> Void

    var body: some View {
        Button(action: showPhoto) {
            HStack(spacing: 14) {
                thumbnail
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle().fill(episode.kind == .cry ? Theme.loud : Theme.middle).frame(width: 8, height: 8)
                        Text(live ? "Právě teď" : episode.title).font(.headline)
                    }
                    Text("\(timeText(episode.start)) · \(durationText(episode.duration))")
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if Moments.image(for: episode.id) != nil {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if let image = Moments.image(for: episode.id) {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: 72, height: 44).clipShape(shape)
        } else {
            shape.fill(Color.secondary.opacity(0.12))
                .frame(width: 72, height: 44)
                .overlay(Image(systemName: "waveform").foregroundStyle(.secondary))
        }
    }
}

struct PhotoItem: Identifiable {
    let id = UUID()
    let image: UIImage
    let episode: SoundActivity.Episode
}

private struct PhotoView: View {
    let item: PhotoItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: item.image).resizable().scaledToFit()
            }
            .navigationTitle("\(item.episode.title) v \(timeText(item.episode.start))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Hotovo") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: Image(uiImage: item.image),
                              preview: SharePreview("Chůvička", image: Image(uiImage: item.image)))
                }
            }
            .environment(\.colorScheme, .dark)
        }
    }
}

/// The last hour at a glance, on the main screen. A tap opens the Overview.
struct HourStrip: View {
    @ObservedObject var activity: SoundActivity
    let open: () -> Void

    var body: some View {
        let since = Date().addingTimeInterval(-3600)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Poslední hodina").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(summary(since: since)).font(.footnote).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                Timeline(activity: activity, since: since, height: 28)
                HStack {
                    Text("před hodinou")
                    Spacer()
                    Text("teď")
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(16)
            .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous), interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Poslední hodina. \(summary(since: since))")
        .accessibilityHint("Otevře přehled")
    }

    private func summary(since: Date) -> String {
        if activity.current != nil { return "Právě se ozývá" }
        let episodes = activity.episodes(since: since)
        if activity.listened(since: since) < 60 { return "Zatím bez záznamu" }
        guard let last = episodes.first else { return "Klid" }
        let minutes = Int(Date().timeIntervalSince(last.end) / 60)
        return "\(eventsText(episodes.count)) · naposledy před \(max(minutes, 1)) min"
    }
}
