import SwiftUI
import UIKit

/// Night mode. The screen goes almost black, and the brightness goes to the minimum.
/// Only a dim, slow waveform stays. The phone can lie on the night table and give no light,
/// but one look shows whether the baby makes a sound. A tap anywhere ends it.
struct NightView: View {
    @EnvironmentObject private var engine: MonitorEngine
    let onClose: () -> Void
    @State private var savedBrightness: CGFloat?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.moon.opacity(0.35))
                Waveform(history: engine.history, dim: true)
                    .frame(height: 90)
                    .padding(.horizontal, 32)
                    .opacity(0.8)
                Label(engine.soundStatus.title, systemImage: Theme.symbol(for: engine.soundStatus))
                    .font(.rounded(.subheadline, .medium))
                    // A fault stays bright. A normal state is dim.
                    .foregroundStyle(engine.soundStatus == .lost ? Theme.alarm : Color.white.opacity(0.3))
                Spacer()
                Text("Tap to wake the screen")
                    .font(.rounded(.caption))
                    .foregroundStyle(.white.opacity(0.18))
                    .padding(.bottom, 24)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.tap()
            onClose()
        }
        .onAppear {
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 0.01
        }
        .onDisappear(perform: restore)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in restore() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 0.01
        }
    }

    private func restore() {
        if let savedBrightness { UIScreen.main.brightness = savedBrightness }
        savedBrightness = nil
    }
}
