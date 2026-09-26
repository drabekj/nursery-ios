import SwiftUI

/// The main screen. It has two views, and the switch at the top chooses:
/// - Obraz: the picture with the frame light, the state band under it, and the controls at the thumb.
/// - Jen zvuk (the glance view): no picture. The state field fills the screen, edge to edge,
///   and the picture tools go away.
///
/// Each view adapts to three shapes: iPhone portrait, landscape (the picture fills the screen),
/// and iPad (the stage on the left, the room and the controls on the right).
struct MonitorView: View {
    @EnvironmentObject private var engine: MonitorEngine
    @EnvironmentObject private var camera: CameraControl
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var battery: BatteryMonitor
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(\.horizontalSizeClass) private var hSize
    /// The real appearance. The views on a field override the colour scheme below this view.
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var zoom = ZoomState()
    @StateObject private var dimmer = FieldDimmer()
    @State private var aiming = false
    @State private var night = false
    @State private var sheet: Sheet?
    @State private var shared: SharedImage?
    @State private var toast: String?
    @State private var flash = false
    @State private var askAlerts = false
    @State private var offerNight = false
    /// "Ukončit hlídání?" Each way to stop asks first: one tap in the dark must not end the monitoring.
    @State private var confirmStop = false

    enum Sheet: String, Identifiable { case settings, activity, help; var id: String { rawValue } }

    private var soundView: Bool { settings.soundView }
    private var wide: Bool { hSize == .regular || vSize == .compact }

    // MARK: The state colours

    private var state: RoomState { engine.roomState }
    /// The dark tokens: in the dark appearance, and after 30 s untouched (auto-dim).
    private var fieldDim: Bool { dimmer.dimmed || scheme == .dark }
    /// The glance view draws the field behind the whole page, also behind the status bar.
    private var onField: Bool { soundView }
    private var fieldColor: Color { Theme.field(for: state, dim: fieldDim) }
    private var onFieldColor: Color { Theme.onField(for: state, dim: fieldDim) }
    /// White type on the field = the dark scheme for the controls on it; ink (bright amber) = light.
    /// The status bar follows (light content on teal, wine, graphite; dark content on amber).
    private var fieldScheme: ColorScheme { Theme.fieldIsLight(state, dim: fieldDim) ? .light : .dark }

    var body: some View {
        ZStack {
            // Night mode covers everything. Then the monitor under it is not built at all:
            // behind the black screen it redrew and animated all night for nobody.
            if !night {
                if vSize == .compact && !soundView {
                    FullScreenMonitor(zoom: zoom, pip: engine.pip, aiming: $aiming, actions: actions)
                } else {
                    if onField {
                        StateFieldBackground(state: state, dim: fieldDim)
                    } else {
                        Theme.background
                    }
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
        // Any touch brings the bright field back and starts the 30 s again.
        .simultaneousGesture(TapGesture().onEnded { dimmer.touch() })
        // An alert, not a confirmation dialog: iOS shows the dialog as a popover and hides its
        // cancel button there. The alert always shows "Zrušit".
        .alert("Ukončit hlídání?", isPresented: $confirmStop) {
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
        // A short message from the engine, for example "Kamera nalezena na nové adrese".
        .onChange(of: engine.notice) { _, n in
            if let n {
                show(n)
                engine.clearNotice()
            }
        }
        .onChange(of: wantsDetail, initial: true) { _, on in engine.setDetail(on) }
        .onChange(of: engine.roomState, initial: true) { _, s in dimmer.state(s) }
        .onChange(of: night) { _, on in if on { dimmer.stop() } else { dimmer.touch() } }
        .task(id: night) { await suggestNight() }
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
                ViewSwitch(soundView: soundView,
                           field: onField ? fieldColor : nil, onField: onField ? onFieldColor : nil,
                           choose: setSoundView)
                    .padding(.top, 4)
                    .padding(.bottom, wide ? 12 : 16)
                if wide { wideContent } else { phoneContent }
            }
            .toolbar { toolbar }
            .navigationTitle("Chůvička")
            .navigationBarTitleDisplayMode(.inline)
            .modifier(FieldBars(scheme: onField ? fieldScheme : nil))
        }
        // The controls on a field take its type colour: white on teal, wine, graphite; ink on amber.
        .environment(\.colorScheme, onField ? fieldScheme : scheme)
        .tint(onField ? onFieldColor : Theme.accent)
    }

    private var stageTransition: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.94)), removal: .opacity)
    }

    // iPhone portrait.
    private var phoneContent: some View {
        VStack(spacing: 0) {
            if soundView {
                if typeSize.isAccessibilitySize {
                    // Large text: the field and the cards scroll, nothing is cut.
                    ScrollView {
                        VStack(spacing: 20) {
                            StateField(dim: fieldDim)
                                .padding(.top, 8)
                            glanceCards
                        }
                        .padding(.bottom, 12)
                    }
                    .transition(stageTransition)
                } else {
                    // The glyph and the word sit in the free space above the cards: the upper 60 %
                    // of the screen, clear of a glass of water in front of the phone.
                    StateField(dim: fieldDim)
                        .frame(maxHeight: .infinity)
                        .transition(stageTransition)
                    glanceCards
                        .padding(.bottom, 12)
                }
            } else {
                VideoHero(zoom: zoom, pip: engine.pip, aiming: $aiming, onMove: move, fullScreen: {
                    Orientation.request(.landscapeRight)
                }, frameColor: Theme.field(for: state, dim: fieldDim))
                .padding(.horizontal, 8)
                .transition(stageTransition)

                StateBand(dim: fieldDim)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .transition(.opacity)
                LiveWaveform(levels: engine.levels, dim: !RoomWords.hearsRoom(engine))
                    .frame(height: 60)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                stripSlot
                    .padding(.horizontal, 16)
                    .padding(.top, 14)

                // The spacer must stay a plain Spacer. Wrapped in a frame, it took half of the free
                // height from the picture, and the picture shrank to 60 % of the width.
                Spacer(minLength: 12)
            }

            controlBar
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: engine.volumeLow)
    }

    /// The glance view, at arm's length: the waveform and the last hour (or a banner) on glass.
    private var glanceCards: some View {
        VStack(spacing: 12) {
            SoundWaveCard(dim: fieldDim)
            stripSlot
        }
        .padding(.horizontal, 16)
    }

    private var controlBar: some View {
        ControlBar(aiming: $aiming, actions: actions, pictureTools: !soundView,
                   field: onField ? fieldColor : nil, onField: onField ? onFieldColor : nil)
    }

    // iPad, and the sound view in landscape.
    private var wideContent: some View {
        HStack(alignment: .top, spacing: 24) {
            if soundView {
                StateField(dim: fieldDim, compact: vSize == .compact)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(stageTransition)
            } else {
                VideoHero(zoom: zoom, pip: engine.pip, aiming: $aiming, onMove: move, fullScreen: nil,
                          frameColor: Theme.field(for: state, dim: fieldDim))
                    .transition(stageTransition)
            }
            VStack(spacing: 20) {
                if soundView {
                    SoundWaveCard(dim: fieldDim)
                } else {
                    StateBand(dim: fieldDim)
                    LiveWaveform(levels: engine.levels, dim: !RoomWords.hearsRoom(engine))
                        .frame(height: 60)
                }
                stripSlot
                Spacer(minLength: 0)
                controlBar
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
        } else if offerNight {
            NightOffer(accept: {
                withAnimation { offerNight = false }
                enterNight()
            }, dismiss: { withAnimation { offerNight = false } })
                .transition(.opacity)
        } else if !wide || vSize != .compact {
            // Landscape (the sound view) has no room for the strip.
            HourStrip(activity: engine.activityLog, state: state, onField: onField) { sheet = .activity }
                .transition(.opacity)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            StatusBadge(overall: engine.overall, pictureLive: engine.pictureLive, dot: onField ? onFieldColor : nil)
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

    // MARK: The night suggestion

    /// The evening that a time belongs to: 1:30 at night is still the evening before.
    private static func evening(_ date: Date = Date()) -> String {
        let shifted = Calendar.current.date(byAdding: .hour, value: -6, to: date) ?? date
        return shifted.formatted(.iso8601.year().month().day())
    }

    /// After 21:00 (until 6:00), on the charger, the monitor up for 3 min: offer Night mode, once
    /// per evening. Not tied to a touch: at 2 a.m. nobody touches the screen first.
    private func suggestNight() async {
        guard !night, !MonitorEngine.isDemo else { return }
        try? await Task.sleep(for: .seconds(180))
        while !Task.isCancelled {
            let hour = Calendar.current.component(.hour, from: Date())
            let evening = Self.evening()
            if (hour >= 21 || hour < 6), battery.charging, !engine.paused, !offerNight,
               UserDefaults.standard.string(forKey: "nightSuggestedDay") != evening {
                UserDefaults.standard.set(evening, forKey: "nightSuggestedDay")
                Log.shared.add("night mode suggested")
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { offerNight = true }
                return
            }
            try? await Task.sleep(for: .seconds(60))
        }
    }

    // MARK: The demo

    /// `-demoScreen aim|night|night-controls|night-cry|activity|settings|remote|help|alerts|paused|stop`
    /// opens a screen at launch, for the screenshots. NightView and SettingsView read the value too.
    /// The state screens (`klid`, `sound-cry`, `sound-lost`, `sound-connecting`, `sound-muted`,
    /// `main-cry`): the engine sets `roomState` (and the muted mode) from the name; here only the view is chosen.
    /// `sound…` opens the sound view already (Settings), `main…` the picture view.
    private func applyDemoScreen() {
        guard MonitorEngine.isDemo else { return }
        Log.shared.add("demo screen \(UserDefaults.standard.string(forKey: "demoScreen") ?? "none")")
        switch UserDefaults.standard.string(forKey: "demoScreen") {
        case "aim": aiming = true
        case "night", "night-controls", "night-cry": night = true
        case "activity": sheet = .activity
        case "settings", "remote", "settings-advanced": sheet = .settings
        case "help": sheet = .help
        case "alerts": askAlerts = true
        case "paused": engine.pause(why: "demo")
        case "klid": engine.setSoundView(true)
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

/// The navigation bar on a field: its colour scheme follows the type on the field, and the status
/// bar with it. SwiftUI applies the bar's colour scheme only with a visible bar background, so the
/// background is "visible" but clear: the field shows through.
private struct FieldBars: ViewModifier {
    let scheme: ColorScheme?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let scheme {
            content
                .toolbarBackground(Color.clear, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(scheme, for: .navigationBar)
        } else {
            content
                .toolbarBackground(.hidden, for: .navigationBar)
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

// MARK: - The status badge

struct StatusBadge: View {
    let overall: MonitorEngine.Overall
    let pictureLive: Bool
    /// On a state field the dot is `onField` (white or ink): green on teal or amber would not show.
    var dot: Color?
    var body: some View {
        HStack(spacing: 7) {
            PulseDot(color: dot ?? color, animated: overall == .live || overall == .soundOnly)
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
                .tint(Theme.moon)          // Dark text needs the yellow, also over a field (tint white or ink there).
                .controlSize(.small)
                Button("Později", action: dismiss).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// After 21:00, on the charger, with the monitor up for 3 min: the persona will not look for
/// the Noční button at 2 a.m., so the app offers it. Once per evening.
struct NightOffer: View {
    let accept: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "moon.stars.fill")
                .font(.title2)
                .foregroundStyle(Color.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Je noc — zapnout Noční režim?").font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Displej bude skoro černý. Zvuk i upozornění běží dál.")
                    .font(.caption).foregroundStyle(Color.primary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                Button(action: accept) {
                    Text("Zapnout").fontWeight(.semibold).foregroundStyle(.black)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.moon)
                .controlSize(.small)
                Button("Teď ne", action: dismiss).font(.caption).foregroundStyle(Color.primary.opacity(0.8))
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
