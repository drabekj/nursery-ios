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
    @EnvironmentObject private var settings: Settings
    let inPictureInPicture: Bool

    var body: some View {
        VStack(spacing: 10) {
            if inPictureInPicture {
                Image(systemName: "pip.fill").font(.largeTitle).foregroundStyle(.secondary)
                Text("Přehrává se v obrazu v obraze").font(.subheadline).foregroundStyle(.secondary)
            } else if case .offline = engine.overall {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 30)).foregroundStyle(Theme.alarm)
                    .symbolEffect(.pulse)
                Text(settings.source == .phone ? "Telefon u miminka je nedostupný" : "Kamera je nedostupná").font(.headline)
                Text(settings.source == .phone
                     ? "Zkontrolujte, že na telefonu u miminka běží vysílání a že jsou oba telefony na stejné Wi-Fi."
                     : "Zkontrolujte, že je telefon připojený k domácí Wi-Fi a že má Chůvička povolený přístup k místní síti.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                HStack(spacing: 10) {
                    Button { engine.reconnect(why: "user asked") } label: {
                        Text("Zkusit znovu").foregroundStyle(.black)
                    }
                    .buttonStyle(.borderedProminent)
                    // iOS Settings, where the access to the local network is. Not the app's settings.
                    Button("Nastavení telefonu") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
                .padding(.top, 2)
                // The raw reason is only in the technical log: a system error string says nothing to a parent.
            } else {
                ProgressView().controlSize(.large).tint(.white)
                Text(waitingText).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.8))
    }

    private var waitingText: String {
        if engine.overall == .reconnecting { return "Obnovování spojení…" }
        guard settings.source == .phone else { return "Připojování ke kameře…" }
        // Live sound with no picture: iOS stopped the camera of the iPhone at the baby.
        return engine.overall == .live ? "Obraz stojí. Je telefon u miminka odemčený a Chůvička na něm otevřená?"
                                       : "Připojování k telefonu u miminka…"
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
                Text("Klepnutím nebo podržením šipky natočíte kameru")
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
                // Not in the demo: a slow simulator took the screenshot after the 20 s, with no arrows.
                if !MonitorEngine.isDemo, Date().timeIntervalSince(lastUse) > 20 { Log.shared.add("aim: 20 s with no use"); done(); break }
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
        .accessibilityLabel("Natočit kameru \(d.czech)")
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
        }
    }

    static func color(_ e: MonitorEngine) -> Color {
        switch e.soundStatus {
        case .lost: Theme.alarm
        case .connecting: .secondary
        default: .primary
        }
    }

    /// Only a state that is not the usual one gets a line. Live sound says nothing: the button already does.
    static func subline(_ e: MonitorEngine, _ settings: Settings) -> String {
        switch e.soundStatus {
        case .listening: settings.loudness == .normal ? "" : "Zesílený zvuk"
        case .silent: "Ztlumeno · při pláči přijde upozornění"
        case .connecting: "Spouštění živého zvuku…"
        case .lost: "Obnovování spojení…"
        }
    }
}

/// The state of the room, in large words, and the last 6 seconds of sound.
struct RoomPanel: View {
    @EnvironmentObject private var engine: MonitorEngine
    @EnvironmentObject private var settings: Settings

    var body: some View {
        let sub = RoomWords.subline(engine, settings)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(RoomWords.headline(engine))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(RoomWords.color(engine))
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.35), value: RoomWords.headline(engine))
                if !sub.isEmpty {
                    Text(sub)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            LiveWaveform(levels: engine.levels, dim: !RoomWords.hearsRoom(engine))
                .frame(height: 84)
        }
    }
}

// MARK: - The control bar

/// The actions, where the thumb is. Sound is the primary one: a tap mutes it or turns it on.
/// The loudness is in the settings.
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
                if pictureTools, camera.canAim || MonitorEngine.isDemo {
                    Button {
                        Haptics.tap()
                        withAnimation(.spring(response: 0.35)) { aiming.toggle() }
                    } label: {
                        BarLabel(title: "Natočit", symbol: "arrow.up.and.down.and.arrow.left.and.right", isOn: aiming, tint: Theme.moon)
                    }
                    .buttonStyle(PressScale())
                    .disabled(engine.connection != .live)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
                if pictureTools, canSnapshot {
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

    /// A plain RTSP camera has no photo. The demo shows the button.
    private var canSnapshot: Bool {
        MonitorEngine.isDemo || settings.source != .camera || settings.cameraKind != .rtsp
    }

    private var soundButton: some View {
        Button {
            Haptics.firm()
            if engine.mode == .off { engine.soundOn() } else { engine.mode = .off }
        } label: {
            // Off is red: a parent must see at a glance that nothing plays.
            BarLabel(title: soundTitle, symbol: engine.mode.symbol, isOn: true,
                     tint: engine.mode == .off ? Theme.alarm : Theme.moon,
                     onForeground: engine.mode == .off ? .white : .black)
        }
        .buttonStyle(PressScale())
        .accessibilityLabel("Zvuk")
        .accessibilityValue(engine.mode.title)
        .accessibilityHint("Dvojitým klepnutím zvuk zapnete nebo ztlumíte. Ztlumená Chůvička dál poslouchá a na pláč upozorní.")
    }

    private var soundTitle: String {
        switch engine.mode {
        case .live: "Zvuk"
        case .off: "Ztlumeno"
        }
    }
}

struct BarLabel: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let tint: Color
    var onForeground: Color = .black

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
        .foregroundStyle(isOn ? onForeground : Color.primary)
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
    @EnvironmentObject private var settings: Settings
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
                        LiveWaveform(levels: engine.levels, last: 30, dim: !RoomWords.hearsRoom(engine))
                            .frame(width: 150, height: 36)
                            .padding(12)
                            .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        Spacer()
                        GlassGroup(spacing: 10) {
                            HStack(spacing: 10) {
                                GlassCircleButton(symbol: engine.mode.symbol, size: 50,
                                                  tint: engine.mode == .off ? Theme.alarm : Theme.moon, label: "Zvuk") {
                                    Haptics.firm()
                                    if engine.mode == .off { engine.soundOn() } else { engine.mode = .off }
                                    scheduleHide()
                                }
                                if camera.canAim || MonitorEngine.isDemo {
                                    GlassCircleButton(symbol: "arrow.up.and.down.and.arrow.left.and.right", size: 50, label: "Natočit kameru") {
                                        aiming = true
                                    }
                                }
                                // A plain RTSP camera has no photo.
                                if MonitorEngine.isDemo || settings.source != .camera || settings.cameraKind != .rtsp {
                                    GlassCircleButton(symbol: "camera.fill", size: 50, label: "Fotka") { actions.snapshot() }
                                }
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
