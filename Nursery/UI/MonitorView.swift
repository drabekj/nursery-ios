import SwiftUI

struct MonitorView: View {
    @EnvironmentObject private var engine: MonitorEngine
    @EnvironmentObject private var camera: CameraControl
    @EnvironmentObject private var settings: Settings
    @Environment(\.verticalSizeClass) private var vSize
    @StateObject private var zoom = ZoomState()
    @State private var showSettings = false
    @State private var night = false
    @State private var toast: String?

    var body: some View {
        ZStack {
            Theme.background
            if vSize == .compact {
                FullScreenMonitor(zoom: zoom, onMove: move)
            } else {
                portrait
            }
            if night {
                NightView { withAnimation(.easeInOut(duration: 0.4)) { night = false } }
                    .transition(.opacity)
                    .zIndex(2)
            }
            if let toast {
                Text(toast)
                    .font(.rounded(.subheadline, .medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(3)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .statusBarHidden(night)
    }

    // MARK: Portrait

    private var portrait: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                VideoCard(zoom: zoom, pip: engine.pip)
                SoundCard()
                if camera.ptzReady { cameraCard }
                if camera.powerReady { powerCard }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Nursery")
                    .font(.rounded(.largeTitle, .bold))
                    .foregroundStyle(.white)
                StatusPill(text: statusText, color: statusColor, pulsing: engine.soundStatus == .listening)
            }
            Spacer()
            GlassCircleButton(symbol: "moon.fill", tint: Theme.moon, label: "Night mode") {
                Haptics.tap()
                withAnimation(.easeInOut(duration: 0.4)) { night = true }
            }
            GlassCircleButton(symbol: "gearshape.fill", label: "Settings") { showSettings = true }
        }
        .padding(.top, 8)
    }

    private var statusText: String {
        switch engine.connection {
        case .live where engine.audioOnly: return "Sound only"
        case .live: return engine.pictureLive ? "Live" : "Waiting for the picture"
        case .connecting, .idle: return "Connecting…"
        case .retrying: return "Reconnecting…"
        }
    }

    private var statusColor: Color {
        switch engine.connection {
        case .live: engine.pictureLive || engine.audioOnly ? Theme.calm : Theme.warn
        case .connecting, .idle: Theme.warn
        case .retrying: Theme.alarm
        }
    }

    private var cameraCard: some View {
        Card {
            HStack(spacing: 18) {
                DirectionPad(enabled: engine.connection == .live, onMove: move)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Move camera")
                        .font(.rounded(.headline, .semibold))
                    Text("Tap an arrow to turn the camera. Hold it to keep turning.")
                        .font(.rounded(.footnote))
                        .foregroundStyle(Theme.secondaryText)
                    Label("Pinch the picture to zoom. The camera does not move.", systemImage: "hand.pinch")
                        .font(.rounded(.caption))
                        .foregroundStyle(Theme.secondaryText.opacity(0.8))
                }
            }
        }
    }

    private var powerCard: some View {
        Card {
            HStack {
                Label("Camera power", systemImage: "power")
                    .font(.rounded(.headline, .semibold))
                Spacer()
                Button("Off") { power(false) }.buttonStyle(.bordered).tint(Theme.alarm)
                Button("On") { power(true) }.buttonStyle(.borderedProminent).tint(Theme.calm)
            }
        }
    }

    // MARK: Actions

    private func move(_ d: CameraControl.Direction) {
        Task {
            if !(await camera.move(d)) { show(camera.lastError ?? "The camera did not move."); Haptics.error() }
        }
    }

    private func power(_ on: Bool) {
        Haptics.firm()
        Task {
            if await camera.power(on: on) { show(on ? "The camera starts. Wait 30 seconds." : "The camera is off.") }
            else { show(camera.lastError ?? "No answer."); Haptics.error() }
        }
    }

    private func show(_ text: String) {
        withAnimation(.spring(response: 0.35)) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeOut) { if toast == text { toast = nil } }
        }
    }
}

// MARK: - The picture card

struct VideoCard: View {
    @EnvironmentObject private var engine: MonitorEngine
    @ObservedObject var zoom: ZoomState
    @ObservedObject var pip: PictureInPicture

    var body: some View {
        let aspect = engine.videoSize.width / max(engine.videoSize.height, 1)
        ZStack {
            ZoomableVideo(videoView: engine.videoView, zoom: zoom)
            if !engine.pictureLive || pip.isActive { placeholder }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.cardStroke))
        .overlay(alignment: .topLeading) {
            if engine.pictureLive {
                Label("LIVE", systemImage: "circle.fill")
                    .labelStyle(LiveBadgeStyle())
                    .padding(10)
            }
        }
        .overlay(alignment: .topTrailing) {
            if zoom.scale > 1.05 {
                Button { zoom.reset(); Haptics.tap() } label: {
                    Text(String(format: "%.1f×", zoom.scale))
                        .font(.rounded(.caption, .bold)).monospacedDigit()
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(10)
                .accessibilityLabel("Reset the zoom")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            PiPButton(pip: pip).padding(10)
        }
        .animation(.easeInOut(duration: 0.25), value: engine.pictureLive)
        .animation(.easeInOut(duration: 0.2), value: zoom.scale > 1.05)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            if pip.isActive {
                Image(systemName: "pip.fill").font(.system(size: 30))
                Text("The picture is in the small window.").font(.rounded(.subheadline))
            } else if case .retrying(let why) = engine.connection {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 30)).foregroundStyle(Theme.alarm)
                Text("The nursery does not answer").font(.rounded(.headline))
                Text(why).font(.rounded(.caption)).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
                Text("Are you on the home Wi-Fi? The app tries again.")
                    .font(.rounded(.caption)).foregroundStyle(Theme.secondaryText)
                Button("Try now") { engine.reconnect(why: "user asked") }
                    .buttonStyle(.bordered).tint(Theme.moon).padding(.top, 4)
            } else {
                ProgressView().tint(Theme.moon)
                Text("Connecting to the nursery…").font(.rounded(.subheadline)).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.75))
        .transition(.opacity)
    }
}

struct PiPButton: View {
    @ObservedObject var pip: PictureInPicture
    var body: some View {
        if pip.isPossible || pip.isActive {
            GlassCircleButton(symbol: pip.isActive ? "pip.exit" : "pip.enter", size: 36,
                              label: pip.isActive ? "Close the small window" : "Open the small window") {
                Haptics.tap()
                pip.toggle()
            }
        }
    }
}

struct LiveBadgeStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 7)).foregroundStyle(Theme.alarm)
            configuration.title.font(.rounded(.caption2, .heavy)).tracking(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: - The sound card

struct SoundCard: View {
    @EnvironmentObject private var engine: MonitorEngine
    @EnvironmentObject private var settings: Settings

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(engine.soundStatus.title, systemImage: Theme.symbol(for: engine.soundStatus))
                        .font(.rounded(.headline, .semibold))
                        .foregroundStyle(Theme.color(for: engine.soundStatus))
                        .contentTransition(.symbolEffect(.replace))
                    Spacer()
                    if engine.soundStatus == .listening {
                        Text(Waveform.word(for: engine.level))
                            .font(.rounded(.subheadline, .medium))
                            .foregroundStyle(Theme.secondaryText)
                            .contentTransition(.opacity)
                            .animation(.easeInOut, value: Waveform.word(for: engine.level))
                    }
                }

                Waveform(history: engine.history, dim: engine.soundStatus != .listening)
                    .frame(height: 56)

                HStack(spacing: 12) {
                    Button {
                        Haptics.firm()
                        engine.listening.toggle()
                    } label: {
                        Label(engine.listening ? "Listening" : "Listen",
                              systemImage: engine.listening ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.rounded(.subheadline, .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(engine.listening ? Color.black : .white)
                            .background(engine.listening ? Theme.moon : Color.white.opacity(0.1),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(PressScale())
                    .accessibilityHint("Turns the sound of the nursery on or off")

                    Picker("Loudness", selection: $settings.loudness) {
                        ForEach(Settings.Loudness.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 190)
                }

                if engine.soundStatus == .listening {
                    Text("Delay \(engine.delayMilliseconds) ms · Continues on the lock screen")
                        .font(.rounded(.caption2))
                        .foregroundStyle(Theme.secondaryText.opacity(0.7))
                        .monospacedDigit()
                }
            }
        }
    }
}

// MARK: - Landscape: the picture fills the screen

struct FullScreenMonitor: View {
    @EnvironmentObject private var engine: MonitorEngine
    @EnvironmentObject private var camera: CameraControl
    @ObservedObject var zoom: ZoomState
    let onMove: (CameraControl.Direction) -> Void
    @State private var chrome = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ZoomableVideo(videoView: engine.videoView, zoom: zoom, onTap: toggleChrome)
                .aspectRatio(engine.videoSize.width / max(engine.videoSize.height, 1), contentMode: .fit)
                .ignoresSafeArea()
            if chrome {
                VStack {
                    HStack {
                        StatusPill(text: engine.soundStatus.title, color: Theme.color(for: engine.soundStatus),
                                   pulsing: engine.soundStatus == .listening)
                        Spacer()
                        if zoom.scale > 1.05 {
                            GlassCircleButton(symbol: "arrow.down.right.and.arrow.up.left", size: 36, label: "Reset the zoom") {
                                zoom.reset()
                            }
                        }
                        PiPButton(pip: engine.pip)
                    }
                    Spacer()
                    HStack(alignment: .bottom) {
                        Waveform(history: Array(engine.history.suffix(30)))
                            .frame(width: 150, height: 34)
                            .padding(10)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        Spacer()
                        if camera.ptzReady {
                            DirectionPad(enabled: engine.connection == .live, onMove: { d in onMove(d); scheduleHide() }, size: 120)
                        }
                    }
                }
                .padding(20)
                .transition(.opacity)
            }
        }
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
