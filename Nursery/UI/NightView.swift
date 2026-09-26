import SwiftUI
import UIKit

/// Night mode: a phone on the night table that gives no light, but answers two questions at a glance:
/// what time is it, and is the baby making a sound.
///
/// What it does, and what the explainer tells the parent:
/// - The screen stays on at the minimum brightness, almost black. The phone does not lock by itself.
/// - The picture stops (sound only), which saves the battery. The sound and the alerts continue.
/// - A sound makes the waveform brighter for its length.
/// - A tap wakes the screen. Locking the phone is still fine: the sound continues.
struct NightView: View {
    @EnvironmentObject private var engine: MonitorEngine
    @EnvironmentObject private var battery: BatteryMonitor
    @EnvironmentObject private var settings: Settings
    @ObservedObject var activity: SoundActivity
    let onClose: () -> Void
    @State private var savedBrightness: CGFloat?
    @State private var explain = !UserDefaults.standard.bool(forKey: "nightExplained")

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
                Text("Klepnutím probudíte displej")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.16))
                    .padding(.bottom, 20)
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
            onClose()
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Noční režim. \(statusText). Dvojitým klepnutím probudíte displej.")
        .onAppear {
            engine.setNightMode(true)
            UIApplication.shared.isIdleTimerDisabled = true      // The phone does not lock by itself.
            dim()
        }
        .onDisappear {
            engine.setNightMode(false)
            UIApplication.shared.isIdleTimerDisabled = settings.keepAwake
            restore()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in restore() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in dim() }
    }

    private var statusText: String {
        if engine.volumeLow { return "Hlasitost iPhonu je nízká" }
        return activity.current != nil ? "Ozývá se" : engine.soundStatus.title
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
