import SwiftUI

/// The main screen. It has two views, and the switch at the top chooses:
/// - Obraz: the picture, the room below it, and the controls at the thumb.
/// - Jen zvuk: no picture. The room fills the screen, and the picture tools go away.
///
/// Each view adapts to three shapes: iPhone portrait, landscape (the picture fills the screen),
/// and iPad (the stage on the left, the room and the controls on the right).
struct MonitorView: View {
    @EnvironmentObject private var engine: MonitorEngine
    @EnvironmentObject private var camera: CameraControl
    @EnvironmentObject private var settings: Settings
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(\.horizontalSizeClass) private var hSize
    @StateObject private var zoom = ZoomState()
    @State private var aiming = false
    @State private var night = false
    @State private var sheet: Sheet?
    @State private var shared: SharedImage?
    @State private var toast: String?
    @State private var flash = false
    @State private var askAlerts = false

    enum Sheet: String, Identifiable { case settings, activity, help; var id: String { rawValue } }

    private var soundView: Bool { settings.soundView }
    private var wide: Bool { hSize == .regular || vSize == .compact }

    var body: some View {
        ZStack {
            AmbientBackground(level: engine.level, status: engine.soundStatus)
            if vSize == .compact && !soundView {
                FullScreenMonitor(zoom: zoom, pip: engine.pip, aiming: $aiming, actions: actions)
            } else {
                mainLayout
            }
            if flash {
                Color.white.ignoresSafeArea().transition(.opacity).allowsHitTesting(false).zIndex(4)
            }
            if night {
                NightView(activity: engine.activityLog) { withAnimation(.easeInOut(duration: 0.5)) { night = false } }
                    .transition(.opacity)
                    .zIndex(5)
            }
        }
        .overlay(alignment: .top) { toastView }
        .sheet(item: $sheet) { s in
            switch s {
            case .settings: SettingsView()
            case .activity: ActivityView(activity: engine.activityLog).presentationDetents([.large])
            case .help: HelpView()
            }
        }
        .sheet(item: $shared) { item in ShareSheet(items: [item.image]).presentationDetents([.medium, .large]) }
        .statusBarHidden(night)
        .persistentSystemOverlays(night ? .hidden : .automatic)
        .onChange(of: engine.connection) { _, c in
            if c == .live { Task { await offerAlerts() } }
        }
        .onAppear(perform: applyDemoScreen)
    }

    private var actions: MonitorActions {
        MonitorActions(snapshot: snapshot, night: { enterNight() }, move: move)
    }

    private func setSoundView(_ on: Bool) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
            aiming = false
            engine.setSoundView(on)
        }
    }

    // MARK: The layout

    private var mainLayout: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ViewSwitch(soundView: soundView, choose: setSoundView)
                    .padding(.top, 4)
                    .padding(.bottom, wide ? 12 : 16)
                if wide { wideContent } else { phoneContent }
            }
            .toolbar { toolbar }
            .navigationTitle("Chůvička")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    private var stageTransition: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.94)), removal: .opacity)
    }

    // iPhone portrait.
    private var phoneContent: some View {
        VStack(spacing: 0) {
            if soundView {
                SoundStage(activity: engine.activityLog) { sheet = .activity }
                    .padding(.horizontal, 20)
                    .transition(stageTransition)
                PeekCard { setSoundView(false) }
                    .padding(.horizontal, 16)
                    .padding(.top, 22)
                    .transition(.opacity)
            } else {
                VideoHero(zoom: zoom, pip: engine.pip, aiming: $aiming, onMove: move, fullScreen: {
                    Orientation.request(.landscapeRight)
                })
                .padding(.horizontal, 8)
                .transition(stageTransition)

                RoomPanel(activity: engine.activityLog) { sheet = .activity }
                    .padding(.horizontal, 20)
                    .padding(.top, 22)
                    .transition(.opacity)
            }

            HourStrip(activity: engine.activityLog) { sheet = .activity }
                .padding(.horizontal, 16)
                .padding(.top, soundView ? 12 : 20)

            Spacer(minLength: 12).frame(maxHeight: soundView ? 16 : .infinity)

            if askAlerts {
                AlertOffer(allow: allowAlerts, dismiss: { withAnimation { askAlerts = false } })
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            ControlBar(aiming: $aiming, actions: actions, pictureTools: !soundView)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
    }

    // iPad, and the sound view in landscape.
    private var wideContent: some View {
        HStack(alignment: .top, spacing: 24) {
            if soundView {
                SoundStage(activity: engine.activityLog) { sheet = .activity }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(stageTransition)
            } else {
                VideoHero(zoom: zoom, pip: engine.pip, aiming: $aiming, onMove: move, fullScreen: nil)
                    .transition(stageTransition)
            }
            VStack(spacing: 20) {
                if soundView {
                    PeekCard { setSoundView(false) }
                } else {
                    RoomPanel(activity: engine.activityLog) { sheet = .activity }
                }
                if vSize != .compact {
                    HourStrip(activity: engine.activityLog) { sheet = .activity }
                }
                Spacer(minLength: 0)
                if askAlerts { AlertOffer(allow: allowAlerts, dismiss: { askAlerts = false }) }
                ControlBar(aiming: $aiming, actions: actions, pictureTools: !soundView)
            }
            .frame(width: 360)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, vSize == .compact ? 8 : 24)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            StatusBadge(overall: engine.overall, pictureLive: engine.pictureLive)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { sheet = .activity } label: { Label("Přehled", systemImage: "chart.bar.xaxis") }
                Button { sheet = .help } label: { Label("Jak Chůvička funguje", systemImage: "questionmark.circle") }
                Button { sheet = .settings } label: { Label("Nastavení", systemImage: "gearshape") }
                Divider()
                Button { engine.reconnect(why: "menu") } label: { Label("Znovu připojit", systemImage: "arrow.clockwise") }
            } label: {
                Image(systemName: "ellipsis")
                    .accessibilityLabel("Další")
            }
        }
    }

    // MARK: The actions

    private func move(_ d: CameraControl.Direction) {
        Task {
            if !(await camera.move(d)) {
                Haptics.error()
                show(camera.lastError ?? "Kamera se neotočila.")
            }
        }
    }

    private func snapshot() {
        Task {
            guard let image = await camera.snapshot() else {
                Haptics.error()
                show("Žádný obraz. Je kamera zapnutá?")
                return
            }
            Haptics.firm()
            withAnimation(.easeOut(duration: 0.08)) { flash = true }
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.easeIn(duration: 0.35)) { flash = false }
            shared = SharedImage(image: image)
        }
    }

    private func enterNight() {
        Haptics.tap()
        aiming = false
        withAnimation(.easeInOut(duration: 0.5)) { night = true }
    }

    private func show(_ text: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeOut) { if toast == text { toast = nil } }
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Label(toast, systemImage: "exclamationmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16).padding(.vertical, 11)
                .glass(in: Capsule())
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// After the first good connection, offer the alerts. A prompt at launch has no context.
    private func offerAlerts() async {
        guard !MonitorEngine.isDemo, !UserDefaults.standard.bool(forKey: "alertOfferShown") else { return }
        if await NurseryAlerts.authorizationStatus() == .notDetermined {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { askAlerts = true }
        }
    }

    private func allowAlerts() {
        UserDefaults.standard.set(true, forKey: "alertOfferShown")
        NurseryAlerts.requestPermission()
        withAnimation { askAlerts = false }
    }

    /// `-demoScreen aim|night|activity|settings` opens a screen at launch, for the screenshots.
    private func applyDemoScreen() {
        guard MonitorEngine.isDemo else { return }
        switch UserDefaults.standard.string(forKey: "demoScreen") {
        case "aim": aiming = true
        case "night": night = true
        case "activity": sheet = .activity
        case "settings": sheet = .settings
        case "help": sheet = .help
        case "alerts": askAlerts = true
        default: break
        }
    }
}

struct MonitorActions {
    let snapshot: () -> Void
    let night: () -> Void
    let move: (CameraControl.Direction) -> Void
}

// MARK: - The ambient light

/// A soft glow behind the room panel. It follows the loudness, so the whole screen breathes
/// with the room. It is dim on purpose: this screen is often the only light at night.
struct AmbientBackground: View {
    let level: Float
    let status: NurseryActivityAttributes.Status
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Theme.skyTop.ignoresSafeArea()
            RadialGradient(colors: [glow.opacity(0.10 + Double(level) * 0.28), .clear],
                           center: UnitPoint(x: 0.5, y: 0.62), startRadius: 10, endRadius: 420)
                .ignoresSafeArea()
                .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: level)
        }
    }

    private var glow: Color {
        switch status {
        case .lost: Theme.alarm
        case .muted, .connecting: Theme.glowNeutral
        default: Theme.level(level)
        }
    }
}

// MARK: - The status badge

struct StatusBadge: View {
    let overall: MonitorEngine.Overall
    let pictureLive: Bool
    var body: some View {
        HStack(spacing: 7) {
            PulseDot(color: color, animated: overall == .live || overall == .soundOnly)
            Text(text)
                .font(.subheadline.weight(.semibold))
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        switch overall {
        case .live: pictureLive ? "Živě" : "Čekání na obraz"
        case .soundOnly: "Živě"          // The switch already says "Jen zvuk".
        case .connecting: "Připojování"
        case .reconnecting: "Obnovování spojení"
        case .offline: "Nedostupné"
        }
    }

    private var color: Color {
        switch overall {
        case .live, .soundOnly: pictureLive || overall == .soundOnly ? Theme.alarm : Theme.warn   // Red dot: live, as in the Camera app.
        case .connecting, .reconnecting: Theme.warn
        case .offline: Color.gray
        }
    }
}

// MARK: - The alert offer

struct AlertOffer: View {
    let allow: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "bell.badge.fill")
                .font(.title2)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Upozornění na výpadek i na pláč").font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Chůvička vás upozorní, když se přeruší spojení nebo když se miminko ozve.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                Button(action: allow) {
                    Text("Povolit").fontWeight(.semibold).foregroundStyle(.black)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Později", action: dismiss).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
