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
    /// "Ukončit hlídání?" Each way to stop asks first: one tap in the dark must not end the monitoring.
    @State private var confirmStop = false

    enum Sheet: String, Identifiable { case settings, activity, help; var id: String { rawValue } }

    private var soundView: Bool { settings.soundView }
    private var wide: Bool { hSize == .regular || vSize == .compact }
    /// A plain RTSP camera gives no photo, so the photo card has nothing to show.
    private var canPeek: Bool { MonitorEngine.isDemo || settings.source != .camera || settings.cameraKind != .rtsp }

    var body: some View {
        ZStack {
            // Night mode covers everything. Then the monitor under it is not built at all:
            // behind the black screen it redrew and animated all night for nobody.
            if !night {
                AmbientBackground(room: engine.roomLevel, status: engine.soundStatus)
                if vSize == .compact && !soundView {
                    FullScreenMonitor(zoom: zoom, pip: engine.pip, aiming: $aiming, actions: actions)
                } else {
                    mainLayout
                }
            } else {
                Color.black.ignoresSafeArea()
            }
            if flash {
                Color.white.ignoresSafeArea().transition(.opacity).allowsHitTesting(false).zIndex(4)
            }
            if night {
                NightView(activity: engine.activityLog,
                          onClose: { withAnimation(.easeInOut(duration: 0.5)) { night = false } },
                          // Night mode stays under the question. It ends only with the stop.
                          onStop: { confirmStop = true })
                    .transition(.opacity)
                    .zIndex(5)
            }
            if engine.paused {
                PausedView { withAnimation(.easeInOut(duration: 0.4)) { engine.unpause() } }
                    .transition(.opacity)
                    .zIndex(6)
            }
        }
        .overlay(alignment: .top) { toastView }
        .confirmationDialog("Ukončit hlídání?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Ukončit hlídání", role: .destructive, action: stop)
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text("Chůvička přestane poslouchat a nepřijde žádné upozornění.")
        }
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
        .onChange(of: aiming) { _, on in Log.shared.add(on ? "aim on" : "aim off") }
        .onChange(of: wantsDetail, initial: true) { _, on in engine.setDetail(on) }
        .onAppear(perform: applyDemoScreen)
    }

    /// The picture is big (full screen, an iPad) or zoomed in: only then is the main stream worth its cost.
    private var wantsDetail: Bool {
        !night && !soundView && (vSize == .compact || hSize == .regular || zoom.scale > 1.25)
    }

    private var actions: MonitorActions {
        MonitorActions(snapshot: snapshot, night: { enterNight() }, move: move,
                       openSheet: { sheet = $0 }, stop: { confirmStop = true })
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
                SoundStage(activity: engine.activityLog)
                    .padding(.horizontal, 20)
                    .transition(stageTransition)
                if canPeek {
                    PeekCard()
                        .padding(.horizontal, 16)
                        .padding(.top, 22)
                        .transition(.opacity)
                }
            } else {
                VideoHero(zoom: zoom, pip: engine.pip, aiming: $aiming, onMove: move, fullScreen: {
                    Orientation.request(.landscapeRight)
                })
                .padding(.horizontal, 8)
                .transition(stageTransition)

                RoomPanel(activity: engine.activityLog)
                    .padding(.horizontal, 20)
                    .padding(.top, 22)
                    .transition(.opacity)
            }

            stripSlot
                .padding(.horizontal, 16)
                .padding(.top, soundView ? 12 : 20)

            // The spacer must stay a plain Spacer. Wrapped in a frame, it took half of the free
            // height from the picture, and the picture shrank to 60 % of the width.
            if soundView { Spacer().frame(height: 16) } else { Spacer(minLength: 12) }

            ControlBar(aiming: $aiming, actions: actions, pictureTools: !soundView)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: engine.volumeLow)
    }

    // iPad, and the sound view in landscape.
    private var wideContent: some View {
        HStack(alignment: .top, spacing: 24) {
            if soundView {
                SoundStage(activity: engine.activityLog)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(stageTransition)
            } else {
                VideoHero(zoom: zoom, pip: engine.pip, aiming: $aiming, onMove: move, fullScreen: nil)
                    .transition(stageTransition)
            }
            VStack(spacing: 20) {
                if soundView {
                    if canPeek { PeekCard() }
                } else {
                    RoomPanel(activity: engine.activityLog)
                }
                stripSlot
                Spacer(minLength: 0)
                ControlBar(aiming: $aiming, actions: actions, pictureTools: !soundView)
            }
            .frame(width: 360)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, vSize == .compact ? 8 : 24)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: engine.volumeLow)
    }

    /// A banner takes the place of the hour strip while it shows. Then the picture keeps its size:
    /// a banner added under the strip made the baby smaller at the moment the app had something to say.
    @ViewBuilder private var stripSlot: some View {
        if engine.volumeLow {
            VolumeWarning(volume: engine.systemVolume)
                .transition(.opacity)
        } else if askAlerts {
            AlertOffer(allow: allowAlerts, dismiss: { withAnimation { dismissAlerts() } })
                .transition(.opacity)
        } else if !wide || vSize != .compact {
            // Landscape (the sound view) has no room for the strip.
            HourStrip(activity: engine.activityLog) { sheet = .activity }
                .transition(.opacity)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            StatusBadge(overall: engine.overall, pictureLive: engine.pictureLive)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { sheet = .activity } label: { Label("Přehled", systemImage: "chart.bar.xaxis") }
                Button { sheet = .settings } label: { Label("Nastavení", systemImage: "gearshape") }
                Button { sheet = .help } label: { Label("Nápověda", systemImage: "questionmark.circle") }
                Divider()
                Button(role: .destructive) { confirmStop = true } label: { Label("Ukončit hlídání", systemImage: "stop.circle") }
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

    /// After "Ukončit hlídání" in the question. It leaves Night mode too.
    private func stop() {
        night = false
        withAnimation(.easeInOut(duration: 0.4)) { engine.pause(why: "user stopped") }
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

    /// "Později" is also an answer: the offer does not come back at the next launch.
    private func dismissAlerts() {
        UserDefaults.standard.set(true, forKey: "alertOfferShown")
        askAlerts = false
    }

    /// `-demoScreen aim|night|night-controls|activity|settings|remote|help|alerts|paused|stop` opens a screen
    /// at launch, for the screenshots. NightView and SettingsView read the value too.
    private func applyDemoScreen() {
        guard MonitorEngine.isDemo else { return }
        Log.shared.add("demo screen \(UserDefaults.standard.string(forKey: "demoScreen") ?? "none")")
        switch UserDefaults.standard.string(forKey: "demoScreen") {
        case "aim": aiming = true
        case "night", "night-controls": night = true
        case "activity": sheet = .activity
        case "settings", "remote", "settings-advanced": sheet = .settings
        case "help": sheet = .help
        case "alerts": askAlerts = true
        case "paused": engine.pause(why: "demo")
        case "stop":
            // A moment after the launch: a dialog asked for before the screen is up does not show.
            Task {
                try? await Task.sleep(for: .seconds(1))
                confirmStop = true
            }
        default: break
        }
    }
}

struct MonitorActions {
    let snapshot: () -> Void
    let night: () -> Void
    let move: (CameraControl.Direction) -> Void
    let openSheet: (MonitorView.Sheet) -> Void
    /// It asks first ("Ukončit hlídání?"), and stops only after the yes.
    let stop: () -> Void
}

// MARK: - The ambient light

/// A soft glow behind the room panel. It follows the loudness, so the whole screen breathes
/// with the room. It is dim on purpose: this screen is often the only light at night.
/// The glow follows the loudness words (Ticho, Slabé zvuky…), which change a few times a minute,
/// not the 10 Hz level: a full-screen gradient under the glass panels made all of them blur again
/// on each tick, and its 0.35 s animation never ended.
struct AmbientBackground: View {
    let room: RoomLevel
    let status: NurseryActivityAttributes.Status
    private var level: Float { room.value }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Theme.skyTop.ignoresSafeArea()
            RadialGradient(colors: [glow.opacity(0.10 + Double(level) * 0.28), .clear],
                           center: UnitPoint(x: 0.5, y: 0.62), startRadius: 10, endRadius: 420)
                .ignoresSafeArea()
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: room)
        }
    }

    private var glow: Color {
        switch status {
        case .lost: Theme.alarm
        case .connecting: Theme.glowNeutral
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
        // Green: all is well. Red means a fault in this app, so the live dot is not red.
        case .live, .soundOnly: pictureLive || overall == .soundOnly ? Theme.calm : Theme.warn
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

/// The monitor is off. It says so plainly, and one button starts it again.
struct PausedView: View {
    let resume: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.accent)
            Text("Hlídání je vypnuté")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .multilineTextAlignment(.center)
            Text("Chůvička teď neposlouchá a nic neukazuje na zamčené obrazovce. Můžete ji klidně zavřít.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button(action: resume) {
                Text("Znovu hlídat").font(.headline).foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .background(Theme.moon, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(PressScale())
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.skyTop.ignoresSafeArea())
    }
}
