import SwiftUI

/// The main screen. It adapts to three shapes:
/// - iPhone portrait: the picture at the top, the room below, the controls at the thumb.
/// - Landscape: the picture fills the screen, and the controls fade.
/// - iPad: the picture on the left, the room and the controls on the right.
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

    enum Sheet: String, Identifiable { case settings, activity; var id: String { rawValue } }

    var body: some View {
        ZStack {
            AmbientBackground(level: engine.level, status: engine.soundStatus)
            if vSize == .compact {
                FullScreenMonitor(zoom: zoom, pip: engine.pip, aiming: $aiming, actions: actions)
            } else if hSize == .regular {
                wideLayout
            } else {
                phoneLayout
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
            case .activity: ActivityView(activity: engine.activityLog).presentationDetents([.medium, .large])
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

    // MARK: iPhone portrait

    private var phoneLayout: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VideoHero(zoom: zoom, pip: engine.pip, aiming: $aiming, onMove: move, fullScreen: {
                    Orientation.request(.landscapeRight)
                })
                .padding(.horizontal, 8)

                RoomPanel(activity: engine.activityLog) { sheet = .activity }
                    .padding(.horizontal, 20)
                    .padding(.top, 22)

                HourStrip(activity: engine.activityLog) { sheet = .activity }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)

                Spacer(minLength: 12)

                if askAlerts {
                    AlertOffer(allow: allowAlerts, dismiss: { withAnimation { askAlerts = false } })
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                ControlBar(aiming: $aiming, actions: actions)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            .toolbar { toolbar }
            .navigationTitle("Nursery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    // MARK: iPad

    private var wideLayout: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 24) {
                VideoHero(zoom: zoom, pip: engine.pip, aiming: $aiming, onMove: move, fullScreen: nil)
                VStack(spacing: 20) {
                    RoomPanel(activity: engine.activityLog) { sheet = .activity }
                    HourStrip(activity: engine.activityLog) { sheet = .activity }
                    Spacer()
                    if askAlerts { AlertOffer(allow: allowAlerts, dismiss: { askAlerts = false }) }
                    ControlBar(aiming: $aiming, actions: actions)
                }
                .frame(width: 360)
            }
            .padding(24)
            .toolbar { toolbar }
            .navigationTitle("Nursery")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            StatusBadge(overall: engine.overall, pictureLive: engine.pictureLive)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { sheet = .activity } label: { Label("Activity", systemImage: "waveform.path.ecg") }
                Button { sheet = .settings } label: { Label("Settings", systemImage: "gearshape") }
                Divider()
                Button { engine.reconnect(why: "menu") } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
            } label: {
                Image(systemName: "ellipsis")
                    .accessibilityLabel("More")
            }
        }
    }

    // MARK: The actions

    private func move(_ d: CameraControl.Direction) {
        Task {
            if !(await camera.move(d)) {
                Haptics.error()
                show(camera.lastError ?? "The camera did not move.")
            }
        }
    }

    private func snapshot() {
        Task {
            guard let image = await camera.snapshot() else {
                Haptics.error()
                show("No picture. Is the camera on?")
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
        case .muted, .connecting: Color.white.opacity(0.4)
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
                .contentTransition(.opacity)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .animation(.easeInOut, value: text)
    }

    private var text: String {
        switch overall {
        case .live: pictureLive ? "Live" : "Waiting for picture"
        case .soundOnly: "Sound only"
        case .connecting: "Connecting"
        case .reconnecting: "Reconnecting"
        case .offline: "Offline"
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
                .foregroundStyle(Theme.moon)
            VStack(alignment: .leading, spacing: 2) {
                Text("Know when the sound stops").font(.subheadline.weight(.semibold))
                Text("Nursery can alert you if the connection drops, or when the baby makes a sound.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                Button(action: allow) {
                    Text("Allow").fontWeight(.semibold).foregroundStyle(.black)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Later", action: dismiss).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
