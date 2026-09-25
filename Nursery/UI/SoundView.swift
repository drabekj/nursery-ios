import SwiftUI
import UIKit

// The sound view: the parent only listens. There is no picture, so the screen leaves out
// everything that belongs to the picture (aim, zoom, photo, the small window) and gives
// the room itself the space: a calm orb that breathes with the sound, the words, and a peek.
//
// Why a parent chooses it: it saves the battery and the Wi-Fi, the phone stays cool,
// and a dark bedroom gets less light from the screen than from a live picture.

// MARK: - The switch

/// "Obraz | Jen zvuk" at the top of the main screen. The pill slides to the chosen side.
struct ViewSwitch: View {
    let soundView: Bool
    let choose: (Bool) -> Void
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            segment(false, "video.fill", "Obraz")
            segment(true, "waveform", "Jen zvuk")
        }
        .padding(4)
        .glass(in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Zobrazení")
    }

    private func segment(_ value: Bool, _ symbol: String, _ title: String) -> some View {
        let selected = soundView == value
        return Button {
            guard !selected else { return }
            Haptics.select()
            choose(value)
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(selected ? Color.black : Color.primary)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background {
                    if selected {
                        Capsule().fill(Theme.moon).matchedGeometryEffect(id: "pill", in: ns)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - The room orb

/// The room as one calm shape. The core shows the state. Three rings show the sound:
/// the inner ring the sound now, the outer rings the sound a moment ago, so a cry spreads out
/// like a ripple on water. When the room is quiet, the orb breathes slowly.
struct RoomOrb: View {
    let history: [Float]
    let status: NurseryActivityAttributes.Status
    let soundNow: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hears: Bool { status == .listening || status == .silent }

    var body: some View {
        GeometryReader { g in
            let d = min(g.size.width, g.size.height)
            let core = d * 0.44
            ZStack {
                ForEach([3, 2, 1], id: \.self) { i in
                    let v = value(ago: (i - 1) * 4)
                    let spread = (d - core) * CGFloat(i) / 3 * CGFloat(0.4 + 0.6 * v)
                    Circle()
                        .fill(color(v).opacity(0.2 - Double(i) * 0.045))
                        .frame(width: core + spread, height: core + spread)
                }
                Circle()
                    .fill(color(value(ago: 0)).opacity(0.22))
                    .frame(width: core, height: core)
                    .glass(in: Circle(), tint: color(value(ago: 0)).opacity(0.25))
                    .overlay { symbol.font(.system(size: core * 0.3, weight: .semibold)) }
            }
            .frame(width: g.size.width, height: g.size.height)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: history)
        }
        .aspectRatio(1, contentMode: .fit)
        .phaseAnimator([false, true]) { view, inhale in
            // The breath: 5 s in, 5 s out. It stops while a sound goes on, so the sound is clear.
            view.scaleEffect(reduceMotion || soundNow || !hears ? 1 : (inhale ? 1.035 : 0.975))
        } animation: { _ in .easeInOut(duration: 5) }
        .accessibilityHidden(true)
    }

    /// The level `ago` ticks back (a tick is 0.1 s), 0 when the app does not hear the room.
    private func value(ago: Int) -> Float {
        guard hears, history.count > ago else { return 0 }
        return history[history.count - 1 - ago]
    }

    private func color(_ v: Float) -> Color {
        switch status {
        case .lost: Theme.alarm
        case .muted, .connecting: Theme.glowNeutral
        default: Theme.level(v)
        }
    }

    @ViewBuilder private var symbol: some View {
        switch status {
        case .connecting:
            ProgressView().controlSize(.large)
        case .lost:
            Image(systemName: "wifi.exclamationmark").foregroundStyle(Theme.alarm)
        case .muted:
            Image(systemName: "speaker.slash.fill").foregroundStyle(.secondary)
        case .listening, .silent:
            Image(systemName: soundNow ? "waveform" : (status == .silent ? "bell.fill" : "moon.zzz.fill"))
                .foregroundStyle(soundNow ? Theme.level(value(ago: 0)) : Color.primary.opacity(0.55))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.variableColor.iterative, isActive: soundNow)
        }
    }
}

// MARK: - The stage

/// The orb, the words, and the last sound. The whole stage opens the Overview.
struct SoundStage: View {
    @EnvironmentObject private var engine: MonitorEngine
    @EnvironmentObject private var settings: Settings
    @ObservedObject var activity: SoundActivity
    let openActivity: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            RoomOrb(history: engine.history, status: engine.soundStatus, soundNow: activity.current != nil)
                .frame(maxWidth: 280, maxHeight: 280)
                .frame(maxHeight: .infinity)
                .layoutPriority(-1)          // The orb gives way on a small screen. The words do not.
            VStack(spacing: 4) {
                Text(RoomWords.headline(engine))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(RoomWords.color(engine))
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.35), value: RoomWords.headline(engine))
                Text(RoomWords.subline(engine, settings))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            Button(action: openActivity) {
                LastSoundLabel(activity: activity, alignment: .center)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - The peek

/// One photo of the cot, on request. The parent sees the baby without the live picture:
/// no stream, no battery cost. A tap takes a new photo. The button on the right opens the live picture.
struct PeekCard: View {
    @EnvironmentObject private var camera: CameraControl
    let openPicture: () -> Void
    @State private var image: UIImage?
    @State private var taken: Date?
    @State private var loading = false
    @State private var failed = false
    @State private var enlarged = false

    var body: some View {
        HStack(spacing: 14) {
            Button(action: peek) {
                HStack(spacing: 14) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 3) {
                        Text(image == nil ? "Nahlédnout do postýlky" : "Fotka z kamery")
                            .font(.subheadline.weight(.semibold))
                        subtitle
                            .font(.caption)
                            .foregroundStyle(failed ? Theme.alarm : .secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(loading)
            .accessibilityHint("Pořídí novou fotku z kamery")

            GlassCircleButton(symbol: "video.fill", size: 44, label: "Živý obraz", action: openPicture)
        }
        .padding(12)
        .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .sheet(isPresented: $enlarged) {
            if let image { PeekPhoto(image: image, taken: taken ?? Date()) }
        }
        .task {
            if MonitorEngine.isDemo { peek() }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack {
            shape.fill(Color.secondary.opacity(0.12))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .transition(.opacity)
                    .onTapGesture { enlarged = true }
            } else if !loading {
                Image(systemName: "eye.fill").font(.title3).foregroundStyle(.secondary)
            }
            if loading {
                ProgressView()
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(shape)
        .animation(.easeInOut(duration: 0.3), value: image == nil)
    }

    @ViewBuilder private var subtitle: some View {
        if failed {
            Text("Kamera neodpověděla. Zkuste to znovu.")
        } else if loading {
            Text("Fotím…")
        } else if let taken {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text("\(taken.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated).locale(Locale(identifier: "cs_CZ")))) · klepnutím obnovíte")
                    .monospacedDigit()
            }
        } else {
            Text("Jedna fotka, bez živého obrazu")
        }
    }

    private func peek() {
        guard !loading else { return }
        Haptics.tap()
        loading = true
        failed = false
        Task {
            let photo = await camera.snapshot()
            withAnimation {
                loading = false
                if let photo {
                    image = photo
                    taken = Date()
                } else {
                    failed = true
                    Haptics.error()
                }
            }
        }
    }
}

private struct PeekPhoto: View {
    let image: UIImage
    let taken: Date
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image).resizable().scaledToFit()
            }
            .navigationTitle("Fotka v \(taken.formatted(.dateTime.hour().minute().locale(Locale(identifier: "cs_CZ"))))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Hotovo") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview("Chůvička", image: Image(uiImage: image)))
                }
            }
            .environment(\.colorScheme, .dark)
        }
    }
}
