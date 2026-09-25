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
                .accessibilityLabel("Zoom \(String(format: "%.1f", zoom.scale)) times. Tap to reset.")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !aiming, engine.pictureLive {
                HStack(spacing: 8) {
                    PiPButton(pip: pip)
                    if let fullScreen {
                        GlassCircleButton(symbol: "arrow.up.left.and.arrow.down.right", size: 38, label: "Full screen", action: fullScreen)
                    }
                }
                .padding(12)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: engine.pictureLive)
        .animation(.spring(response: 0.3), value: zoom.scale > 1.05)
        .animation(.easeInOut(duration: 0.2), value: aiming)
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
                Text("Playing in picture in picture").font(.subheadline).foregroundStyle(.secondary)
            } else if case .offline(let why) = engine.overall {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 30)).foregroundStyle(Theme.alarm)
                    .symbolEffect(.pulse)
                Text("Can’t reach the nursery").font(.headline)
                Text("Check that this phone is on the home Wi-Fi, and that Nursery may use the local network.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                HStack(spacing: 10) {
                    Button("Try Again") { engine.reconnect(why: "user asked") }
                        .buttonStyle(.borderedProminent)
                    Button("Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
                .padding(.top, 2)
                Text(why).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            } else {
                ProgressView().controlSize(.large).tint(.white)
                Text(engine.overall == .reconnecting ? "Reconnecting…" : "Connecting to the nursery…")
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
                Text("Tap or hold an arrow to turn the camera")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glass(in: Capsule())
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button("Done", action: done)
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
                if Date().timeIntervalSince(lastUse) > 20 { done(); break }
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
        .accessibilityLabel("Turn the camera \(d.rawValue)")
    }
}

struct PiPButton: View {
    @ObservedObject var pip: PictureInPicture
    var body: some View {
        if pip.isPossible || pip.isActive {
            GlassCircleButton(symbol: pip.isActive ? "pip.exit" : "pip.enter", size: 38,
                              label: pip.isActive ? "Stop picture in picture" : "Picture in picture") {
                Haptics.tap()
                pip.toggle()
            }
        }
    }
}

// MARK: - The room

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
                    Text(headline)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(headlineColor)
                        .contentTransition(.interpolate)
                        .animation(.easeInOut(duration: 0.3), value: headline)
                    Text(subline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: openActivity) { lastSound }
                    .buttonStyle(.plain)
            }
            .accessibilityElement(children: .combine)

            Waveform(history: engine.history, dim: !hearsRoom)
                .frame(height: 84)
        }
    }

    private var hearsRoom: Bool { engine.soundStatus == .listening || engine.soundStatus == .silent }

    private var headline: String {
        switch engine.soundStatus {
        case .listening, .silent: Waveform.word(for: engine.level)
        case .connecting: "Connecting"
        case .lost: "No sound"
        case .muted: "Sound off"
        }
    }

    private var headlineColor: Color {
        switch engine.soundStatus {
        case .lost: Theme.alarm
        case .muted, .connecting: .secondary
        default: .primary
        }
    }

    private var subline: String {
        switch engine.soundStatus {
        case .listening:
            settings.loudness == .normal ? "Live sound" : "Live sound · \(settings.loudness.title) +\(Int(settings.loudness.decibels)) dB"
        case .silent: "Silent · you get an alert on sound"
        case .connecting: "Starting the live sound…"
        case .lost: "Reconnecting to the camera…"
        case .muted: "Tap Sound to listen"
        }
    }

    @ViewBuilder private var lastSound: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if activity.current != nil {
                Label("Sound now", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.warn)
                    .symbolEffect(.pulse)
            } else if let last = activity.lastSound {
                Text("Last sound").font(.caption).foregroundStyle(.secondary)
                (Text(last, style: .relative) + Text(" ago"))
                    .font(.footnote.weight(.semibold)).monospacedDigit()
            } else {
                Text("No sounds yet").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6)
        .contentShape(Rectangle())
        .accessibilityHint("Shows the sound activity")
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

    var body: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                soundButton
                if camera.ptzReady || MonitorEngine.isDemo {
                    Button {
                        Haptics.tap()
                        withAnimation(.spring(response: 0.35)) { aiming.toggle() }
                    } label: {
                        BarLabel(title: "Move", symbol: "arrow.up.and.down.and.arrow.left.and.right", isOn: aiming, tint: Theme.moon)
                    }
                    .buttonStyle(PressScale())
                    .disabled(engine.connection != .live)
                }
                Button(action: actions.snapshot) {
                    BarLabel(title: "Photo", symbol: "camera.fill", isOn: false, tint: Theme.moon)
                }
                .buttonStyle(PressScale())
                Button(action: actions.night) {
                    BarLabel(title: "Night", symbol: "moon.fill", isOn: false, tint: Theme.moon)
                }
                .buttonStyle(PressScale())
            }
        }
    }

    private var soundButton: some View {
        Menu {
            Picker("Sound", selection: $engine.mode) {
                ForEach(MonitorEngine.SoundMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            Picker("Loudness", selection: $settings.loudness) {
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
        .accessibilityLabel("Sound")
        .accessibilityValue(engine.mode.title)
        .accessibilityHint("Double tap to turn the sound on or off. Touch and hold for more options.")
    }

    private var soundTitle: String {
        switch engine.mode {
        case .live: "Sound"
        case .silent: "Silent"
        case .off: "Muted"
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
                            GlassCircleButton(symbol: "arrow.down.right.and.arrow.up.left", size: 40, label: "Reset the zoom") { zoom.reset() }
                        }
                        PiPButton(pip: pip)
                        GlassCircleButton(symbol: "xmark", size: 40, label: "Leave full screen") {
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
                                                  tint: engine.mode == .off ? .white : Theme.moon, label: "Sound") {
                                    Haptics.firm()
                                    if engine.mode == .off { engine.soundOn() } else { engine.mode = .off }
                                    scheduleHide()
                                }
                                if camera.ptzReady || MonitorEngine.isDemo {
                                    GlassCircleButton(symbol: "arrow.up.and.down.and.arrow.left.and.right", size: 50, label: "Move camera") {
                                        aiming = true
                                    }
                                }
                                GlassCircleButton(symbol: "camera.fill", size: 50, label: "Photo") { actions.snapshot() }
                            }
                        }
                    }
                }
                .padding(20)
                .transition(.opacity)
            }
        }
        .persistentSystemOverlays(.hidden)
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
