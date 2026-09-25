import SwiftUI
import UIKit

/// Night mode. The screen goes almost black at the minimum brightness.
/// A dim clock and a dim waveform stay. The phone can lie on the night table and give no light,
/// but one look shows the time and whether the baby makes a sound.
/// When a sound event starts, the waveform grows brighter for its length. A tap ends the mode.
struct NightView: View {
    @EnvironmentObject private var engine: MonitorEngine
    @ObservedObject var activity: SoundActivity
    let onClose: () -> Void
    @State private var savedBrightness: CGFloat?

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
                Waveform(history: engine.history, dim: !sound)
                    .frame(height: 90)
                    .padding(.horizontal, 36)
                    .opacity(sound ? 0.95 : 0.55)
                    .animation(.easeInOut(duration: 0.6), value: sound)
                Label(statusText, systemImage: Theme.symbol(for: engine.soundStatus))
                    .font(.subheadline.weight(.medium))
                    // A fault stays bright. A normal state stays dim.
                    .foregroundStyle(engine.soundStatus == .lost ? Theme.alarm : Color.white.opacity(sound ? 0.6 : 0.28))
                Spacer()
                Text("Tap to wake")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.16))
                    .padding(.bottom, 20)
            }
        }
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.tap()
            onClose()
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Night mode. \(statusText). Double tap to wake the screen.")
        .onAppear(perform: dim)
        .onDisappear(perform: restore)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in restore() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in dim() }
    }

    private var statusText: String {
        activity.current != nil ? "Sound now" : engine.soundStatus.title
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
