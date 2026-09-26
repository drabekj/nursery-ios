import SwiftUI
import UIKit

/// `-demoScreen night-controls`: the row of controls shows at once and stays, for the screenshot.
private let demoControls = MonitorEngine.isDemo && UserDefaults.standard.string(forKey: "demoScreen") == "night-controls"

/// Night mode: a phone on the night table that gives no light, but answers two questions at a glance:
/// what time is it, and is the baby making a sound.
///
/// What it does, and what the explainer tells the parent:
/// - The screen stays on at the minimum brightness, almost black. The phone does not lock by itself.
/// - The picture stops (sound only), which saves the battery. The sound and the alerts continue.
/// - A sound makes the waveform brighter for its length.
/// - A tap shows Zvuk, Rozsvítit and Ukončit hlídání for 5 s. A tap beside them hides them again:
///   a missed button must never light the screen. Only Rozsvítit leaves Night mode.
///   Locking the phone is still fine: the sound continues.
struct NightView: View {
    @EnvironmentObject private var engine: MonitorEngine
    @EnvironmentObject private var battery: BatteryMonitor
    @EnvironmentObject private var settings: Settings
    @ObservedObject var activity: SoundActivity
    let onClose: () -> Void
    /// "Ukončit hlídání" in the row of controls. The main screen asks first.
    let onStop: () -> Void
    @State private var savedBrightness: CGFloat?
    @State private var explain = !UserDefaults.standard.bool(forKey: "nightExplained") && !demoControls
    /// The row with Zvuk, Rozsvítit and Ukončit hlídání. A tap shows it for 5 s.
    @State private var controls = demoControls
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        let sound = activity.current != nil
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 26) {
                Spacer()
                TimelineView(.everyMinute) { context in
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 76, weight: .thin, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.moon.opacity(0.22))
                }
                LiveWaveform(levels: engine.levels, dim: !sound)
                    .frame(height: 90)
                    .padding(.horizontal, 36)
                    .opacity(sound ? 0.95 : 0.55)
                    .animation(.easeInOut(duration: 0.6), value: sound)
                Label(statusText, systemImage: Theme.symbol(for: engine.soundStatus))
                    .font(.subheadline.weight(.medium))
                    // A fault stays bright. A normal state stays dim.
                    .foregroundStyle(engine.soundStatus == .lost ? Theme.alarm
                                     : engine.volumeLow ? Theme.warn.opacity(0.8)
                                     : Color.white.opacity(sound ? 0.6 : 0.28))
                Spacer()
                batteryLine
                if controls {
                    VStack(spacing: 12) {
                        controlRow
                        Text("Klepnutím vedle tlačítek je skryjete")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.16))
                    }
                    .padding(.bottom, 20)
                    .transition(.opacity)
                } else {
                    Text("Klepnutím zobrazíte ovládání")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.16))
                        .padding(.bottom, 20)
                }
            }
            .opacity(explain ? 0 : 1)        // The explainer reads alone, with nothing behind it.
            if explain {
                NightExplainer {
                    UserDefaults.standard.set(true, forKey: "nightExplained")
                    withAnimation(.easeOut(duration: 0.3)) { explain = false }
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !explain {
                Button { withAnimation { explain = true } } label: {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.25))
                        .padding(20)
                }
                .accessibilityLabel("Jak funguje noční režim")
            }
        }
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !explain else { return }
            Haptics.tap()
            // The first tap shows the controls. A tap beside them hides them: the screen stays dark.
            if controls { hideControls() } else { showControls() }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(controls ? "Noční režim. \(statusText). Dvojitým klepnutím tlačítka skryjete. Noční režim ukončí tlačítko Rozsvítit."
                                     : "Noční režim. \(statusText). Dvojitým klepnutím zobrazíte tlačítka Zvuk, Rozsvítit a Ukončit hlídání.")
        .onAppear {
            engine.setNightMode(true)
            UIApplication.shared.isIdleTimerDisabled = true      // The phone does not lock by itself.
            dim()
        }
        .onDisappear {
            hideTask?.cancel()
            engine.setNightMode(false)
            UIApplication.shared.isIdleTimerDisabled = settings.keepAwake
            restore()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in restore() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in dim() }
    }

    private var statusText: String {
        // Muted still listens. A lost sound says so, muted or not.
        if engine.mode == .off, engine.soundStatus != .lost { return "Ztlumeno · na pláč upozorní" }
        if engine.volumeLow { return "Hlasitost telefonu je nízká" }
        return activity.current != nil ? "Ozývá se" : engine.soundStatus.title
    }

    /// Zvuk, Rozsvítit and Ukončit hlídání. Dim too: the room is dark, and the parent needs them only for a moment.
    private var controlRow: some View {
        let muted = engine.mode == .off
        return HStack(spacing: 8) {
            Button {
                Haptics.firm()
                if muted { engine.soundOn() } else { engine.mode = .off }
                showControls()          // The 5 s start again.
            } label: {
                nightLabel(muted ? "Ztlumeno" : "Zvuk", engine.mode.symbol,
                           color: muted ? .white : Color.white.opacity(0.85), tint: muted ? Theme.warn : nil)
            }
            .accessibilityLabel("Zvuk")
            .accessibilityValue(engine.mode.title)
            Button {
                Haptics.tap()
                onClose()
            } label: {
                nightLabel("Rozsvítit", "sun.max", color: Color.white.opacity(0.85), tint: nil)
            }
            .accessibilityHint("Ukončí noční režim")
            Button {
                Haptics.firm()
                onStop()
            } label: {
                nightLabel("Ukončit hlídání", "stop.circle", color: Theme.alarm, tint: nil)
            }
        }
        .buttonStyle(PressScale())
        .opacity(0.8)
        .padding(.horizontal, 16)
    }

    private func nightLabel(_ title: String, _ symbol: String, color: Color, tint: Color?) -> some View {
        Label(title, systemImage: symbol)
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 8)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: 50)
            .glass(in: Capsule(), interactive: true, tint: tint)
            .contentShape(Capsule())
    }

    private func hideControls() {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.25)) { controls = false }
    }

    /// It shows the row, and hides it again after 5 s. The demo screenshot keeps it.
    private func showControls() {
        withAnimation(.easeInOut(duration: 0.25)) { controls = true }
        hideTask?.cancel()
        guard !demoControls else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { withAnimation(.easeInOut(duration: 0.4)) { controls = false } }
        }
    }

    /// The battery, dim. It turns red and asks for a charger when the battery is low.
    private var batteryLine: some View {
        HStack(spacing: 6) {
            Image(systemName: battery.charging ? "battery.100.bolt" : battery.isLow ? "battery.25" : "battery.75")
            Text(battery.isLow ? "\(battery.summary) · připojte nabíječku" : battery.summary)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(battery.isLow ? Theme.alarm.opacity(0.8) : Color.white.opacity(0.22))
    }

    private func dim() {
        guard !MonitorEngine.isDemo else { return }
        if savedBrightness == nil { savedBrightness = UIScreen.main.brightness }
        UIScreen.main.brightness = 0.01
    }

    private func restore() {
        if let savedBrightness { UIScreen.main.brightness = savedBrightness }
        savedBrightness = nil
    }
}

/// The short explainer. It shows the first time, and from the (i) button.
private struct NightExplainer: View {
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Noční režim", systemImage: "moon.stars.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.moon)
            point("sun.min", "Displej zůstane zapnutý, ale téměř černý a na nejnižším jasu. Telefon se sám nezamkne.")
            point("waveform", "Zvuk i upozornění běží dál. Obraz se zastaví, aby šetřil baterii.")
            point("hand.tap", "Klepnutím zobrazíte tlačítka Zvuk, Rozsvítit a Ukončit hlídání. Rozsvítit noční režim ukončí.")
            point("battery.100.bolt", "Na celou noc připojte nabíječku. Spotřebu Chůvička měří a ukazuje dole.")
            point("lock.fill", "Chcete šetřit ještě víc? Telefon klidně zamkněte. Zvuk poběží dál i se zamčenou obrazovkou.")
            Button(action: done) {
                Text("Rozumím").fontWeight(.semibold).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Theme.moon, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(PressScale())
            .padding(.top, 4)
        }
        .padding(22)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(24)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).frame(width: 24).foregroundStyle(.white.opacity(0.7))
            Text(text).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
