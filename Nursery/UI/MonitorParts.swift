import SwiftUI
import UIKit

// MARK: - The picture

struct VideoHero: View {
    @EnvironmentObject private var engine: MonitorEngine
    @ObservedObject var zoom: ZoomState
    @ObservedObject var pip: PictureInPicture
    @Binding var aiming: Bool
    let onMove: (CameraControl.Direction) -> Void
    let fullScreen: (() -> Void)?

    var body: some View {
        ZStack {
            Color.black
            ZoomableVideo(videoView: engine.videoView, zoom: zoom)
            if !engine.pictureLive || pip.isActive {
                VideoPlaceholder(inPictureInPicture: pip.isActive)
                    .transition(.opacity)
            }
            if aiming {
                AimOverlay(onMove: onMove) { withAnimation(.spring(response: 0.35)) { aiming = false } }
                    .transition(.opacity)
                    .onAppear { Log.shared.add("aim overlay shown") }
                    .onDisappear { Log.shared.add("aim overlay gone") }
            }
        }
        .aspectRatio(engine.videoSize.width / max(engine.videoSize.height, 1), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if zoom.scale > 1.05, !aiming {
                Button {
                    Haptics.tap()
                    zoom.reset()
                } label: {
                    Label(String(format: "%.1f×", zoom.scale), systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.caption.weight(.bold)).monospacedDigit()
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .glass(in: Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                .padding(12)
                .accessibilityLabel("Přiblížení \(String(format: "%.1f", zoom.scale))×. Klepnutím zrušíte.")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !aiming, engine.pictureLive {
                HStack(spacing: 8) {
                    PiPButton(pip: pip)
                    if let fullScreen {
                        GlassCircleButton(symbol: "arrow.up.left.and.arrow.down.right", size: 38, label: "Celá obrazovka", action: fullScreen)
                    }
                }
                .padding(12)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: engine.pictureLive)
        .animation(.spring(response: 0.3), value: zoom.scale > 1.05)
        .animation(.easeInOut(duration: 0.2), value: aiming)
        .environment(\.colorScheme, .dark)      // Video looks best on black, in both modes.
    }
}

/// What the picture area shows when there is no picture. Each state says what happens,
/// and a fault always gives an action.
struct VideoPlaceholder: View {
    @EnvironmentObject private var engine: MonitorEngine
    let inPictureInPicture: Bool

    var body: some View {
        VStack(spacing: 10) {
            if inPictureInPicture {
                Image(systemName: "pip.fill").font(.largeTitle).foregroundStyle(.secondary)
                Text("Přehrává se v obrazu v obraze").font(.subheadline).foregroundStyle(.secondary)
            } else if case .offline(let why) = engine.overall {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 30)).foregroundStyle(Theme.alarm)
                    .symbolEffect(.pulse)
                Text("Kamera je nedostupná").font(.headline)
                Text("Zkontrolujte, že je telefon připojený k domácí Wi-Fi a že má Chůvička povolený přístup k místní síti.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                HStack(spacing: 10) {
                    Button { engine.reconnect(why: "user asked") } label: {
                        Text("Zkusit znovu").foregroundStyle(.black)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Nastavení") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
                .padding(.top, 2)
                Text(why).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            } else {
                ProgressView().controlSize(.large).tint(.white)
                Text(engine.overall == .reconnecting ? "Obnovování spojení…" : "Připojování ke kameře…")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.8))
    }
}

/// The arrows sit on the picture itself, so the parent watches the result while aiming.
/// This view changes the camera. The pinch zoom changes only this screen.
struct AimOverlay: View {
    let onMove: (CameraControl.Direction) -> Void
    let done: () -> Void
    @State private var hint = true
    @State private var lastUse = Date()

    var body: some View {
        ZStack {
            Color.black.opacity(0.22).allowsHitTesting(false)
            VStack { arrow(.up); Spacer(); arrow(.down) }.padding(10)
            HStack { arrow(.left); Spacer(); arrow(.right) }.padding(10)
            if hint {
                Text("Klepnutím nebo podržením šipky otočíte kameru")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glass(in: Capsule())
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button("Hotovo") { Log.shared.add("aim: Hotovo"); done() }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glass(in: Capsule(), interactive: true)
                .buttonStyle(.plain)
                .padding(12)
        }
        .task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { hint = false }
            // Leave the aiming mode after 20 s with no use.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Date().timeIntervalSince(lastUse) > 20 { Log.shared.add("aim: 20 s with no use"); done(); break }
            }
        }
    }

    private func arrow(_ d: CameraControl.Direction) -> some View {
        RepeatButton(interval: 0.7, action: {
            lastUse = Date()
            withAnimation { hint = false }
            onMove(d)
        }) { pressed in
            Image(systemName: "chevron.\(d.rawValue)")
                .font(.system(size: 20, weight: .bold))
                .frame(width: 54, height: 54)
                .glass(in: Circle(), interactive: true, tint: pressed ? Theme.moon.opacity(0.6) : nil)
                .scaleEffect(pressed ? 0.9 : 1)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: pressed)
        }
        .accessibilityLabel("Otočit kameru \(d.czech)")
    }
}

struct PiPButton: View {
    @ObservedObject var pip: PictureInPicture
    var body: some View {
        if pip.isPossible || pip.isActive {
            GlassCircleButton(symbol: pip.isActive ? "pip.exit" : "pip.enter", size: 38,
                              label: pip.isActive ? "Ukončit obraz v obraze" : "Obraz v obraze") {
                Haptics.tap()
                pip.toggle()
            }
        }
    }
}

// MARK: - The room

/// The words for the state of the room. The picture view and the sound view say the same thing.
@MainActor
enum RoomWords {
    static func hearsRoom(_ e: MonitorEngine) -> Bool { e.soundStatus == .listening || e.soundStatus == .silent }

    static func headline(_ e: MonitorEngine) -> String {
        switch e.soundStatus {
        case .listening, .silent: e.roomLevel.title
        case .connecting: "Připojování"
        case .lost: "Zvuk vypadl"
        case .muted: "Zvuk vypnut"
        }
    }

    static func color(_ e: MonitorEngine) -> Color {
        switch e.soundStatus {
        case .lost: Theme.alarm
        case .muted, .connecting: .secondary
        default: .primary
        }
    }

    static func subline(_ e: MonitorEngine, _ settings: Settings) -> String {
        switch e.soundStatus {
        case .listening:
            settings.loudness == .normal ? "Živý zvuk" : "Živý zvuk · \(settings.loudness.title) +\(Int(settings.loudness.decibels)) dB"
        case .silent: "Tichý režim · při zvuku přijde upozornění"
        case .connecting: "Spouštění živého zvuku…"
        case .lost: "Obnovování spojení s kamerou…"
        case .muted: "Zapnete ho tlačítkem Zvuk"
        }
    }
}

/// The state of the room, in large words, and the last 6 seconds of sound.
struct RoomPanel: View {
    @EnvironmentObject private var engine: MonitorEngine
    @EnvironmentObject private var settings: Settings
    @ObservedObject var activity: SoundActivity
    let openActivity: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(RoomWords.headline(engine))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(RoomWords.color(engine))
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.35), value: RoomWords.headline(engine))
                    Text(RoomWords.subline(engine, settings))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: openActivity) { LastSoundLabel(activity: activity, alignment: .trailing) }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
            }
            .accessibilityElement(children: .combine)

            Waveform(history: engine.history, dim: !RoomWords.hearsRoom(engine))
                .frame(height: 84)
        }
    }
}

/// "Poslední zvuk před 3 min", or "Ozývá se" while a sound goes on.
struct LastSoundLabel: View {
    @ObservedObject var activity: SoundActivity
    var alignment: HorizontalAlignment = .trailing

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            if activity.current != nil {
                HStack(spacing: 7) {
                    PulseDot(color: Theme.warn)
                    Text("Ozývá se")
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.warn)
            } else if let last = activity.lastSound {
                Text("Poslední zvuk").font(.caption).foregroundStyle(.secondary)
                // "před 7 s", "před 3 min": the Czech relative form, updated each second.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(last.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)
                        .locale(Locale(identifier: "cs_CZ"))))
                        .font(.footnote.weight(.semibold)).monospacedDigit()
                        .id(context.date)
                }
            } else {
                Text("Zatím žádný zvuk").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityHint("Otevře přehled")
    }
}

// MARK: - The control bar

/// The four actions, where the thumb is. Sound is the primary one.
/// A long press on Sound opens the sound mode and the loudness.
struct ControlBar: View {
    @EnvironmentObject private var engine: MonitorEngine
    @EnvironmentObject private var camera: CameraControl
    @EnvironmentObject private var settings: Settings
    @Binding var aiming: Bool
    let actions: MonitorActions
    /// Aim and Photo need the picture. The sound view has no picture, so it leaves them out.
    var pictureTools = true

    var body: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                soundButton
                if pictureTools, camera.ptzReady || MonitorEngine.isDemo {
                    Button {
                        Haptics.tap()
                        withAnimation(.spring(response: 0.35)) { aiming.toggle() }
                    } label: {
                        BarLabel(title: "Otočit", symbol: "arrow.up.and.down.and.arrow.left.and.right", isOn: aiming, tint: Theme.moon)
                    }
                    .buttonStyle(PressScale())
                    .disabled(engine.connection != .live)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
                if pictureTools {
                    Button(action: actions.snapshot) {
                        BarLabel(title: "Fotka", symbol: "camera.fill", isOn: false, tint: Theme.moon)
                    }
                    .buttonStyle(PressScale())
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
                Button(action: actions.night) {
                    BarLabel(title: "Noční", symbol: "moon.fill", isOn: false, tint: Theme.moon)
                }
                .buttonStyle(PressScale())
            }
        }
    }

    private var soundButton: some View {
        Menu {
            Picker("Režim zvuku", selection: $engine.mode) {
                ForEach(MonitorEngine.SoundMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            Picker("Hlasitost", selection: $settings.loudness) {
                ForEach(Settings.Loudness.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
        } label: {
            BarLabel(title: soundTitle, symbol: engine.mode.symbol, isOn: engine.mode != .off, tint: Theme.moon)
        } primaryAction: {
            Haptics.firm()
            if engine.mode == .off { engine.soundOn() } else { engine.mode = .off }
        }
        .menuStyle(.button)
        .buttonStyle(PressScale())
        .accessibilityLabel("Zvuk")
        .accessibilityValue(engine.mode.title)
        .accessibilityHint("Dvojitým klepnutím zvuk zapnete nebo vypnete. Podržením zobrazíte další volby.")
    }

    private var soundTitle: String {
        switch engine.mode {
        case .live: "Zvuk"
        case .silent: "Tichý"
        case .off: "Vypnuto"
        }
    }
}

struct BarLabel: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let tint: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(height: 24)
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(isOn ? Color.black : Color.primary)
        .frame(maxWidth: .infinity, minHeight: 66)
        .background(isOn ? tint : Color.clear, in: shape)
        .glass(in: shape, interactive: true)
        .contentShape(shape)
    }
}

// MARK: - Landscape

struct FullScreenMonitor: View {
    @EnvironmentObject private var engine: MonitorEngine
    @EnvironmentObject private var camera: CameraControl
    @ObservedObject var zoom: ZoomState
    @ObservedObject var pip: PictureInPicture
    @Binding var aiming: Bool
    let actions: MonitorActions
    @State private var chrome = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ZStack {
                ZoomableVideo(videoView: engine.videoView, zoom: zoom, onTap: toggleChrome)
                if !engine.pictureLive || pip.isActive { VideoPlaceholder(inPictureInPicture: pip.isActive) }
                if aiming { AimOverlay(onMove: { d in actions.move(d); scheduleHide() }) { aiming = false } }
            }
            .aspectRatio(engine.videoSize.width / max(engine.videoSize.height, 1), contentMode: .fit)
            .ignoresSafeArea()

            if chrome, !aiming {
                VStack {
                    HStack(spacing: 10) {
                        StatusBadge(overall: engine.overall, pictureLive: engine.pictureLive)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .glass(in: Capsule())
                        Spacer()
                        if zoom.scale > 1.05 {
                            GlassCircleButton(symbol: "arrow.down.right.and.arrow.up.left", size: 40, label: "Zrušit přiblížení") { zoom.reset() }
                        }
                        PiPButton(pip: pip)
                        GlassCircleButton(symbol: "xmark", size: 40, label: "Zavřít celou obrazovku") {
                            Orientation.request(.portrait)
                        }
                    }
                    Spacer()
                    HStack(alignment: .bottom) {
                        Waveform(history: Array(engine.history.suffix(30)), dim: engine.mode == .off)
                            .frame(width: 150, height: 36)
                            .padding(12)
                            .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        Spacer()
                        GlassGroup(spacing: 10) {
                            HStack(spacing: 10) {
                                GlassCircleButton(symbol: engine.mode.symbol, size: 50,
                                                  tint: engine.mode == .off ? .primary : Theme.moon, label: "Zvuk") {
                                    Haptics.firm()
                                    if engine.mode == .off { engine.soundOn() } else { engine.mode = .off }
                                    scheduleHide()
                                }
                                if camera.ptzReady || MonitorEngine.isDemo {
                                    GlassCircleButton(symbol: "arrow.up.and.down.and.arrow.left.and.right", size: 50, label: "Otočit kameru") {
                                        aiming = true
                                    }
                                }
                                GlassCircleButton(symbol: "camera.fill", size: 50, label: "Fotka") { actions.snapshot() }
                            }
                        }
                    }
                }
                .padding(20)
                .transition(.opacity)
            }
        }
        .persistentSystemOverlays(.hidden)
        .environment(\.colorScheme, .dark)
        .onAppear(perform: scheduleHide)
        .animation(.easeInOut(duration: 0.25), value: chrome)
    }

    private func toggleChrome() {
        chrome.toggle()
        if chrome { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { chrome = false }
        }
    }
}
