import MediaPlayer
import SwiftUI

/// A warning when the iPhone's own volume is low. The live sound then plays, but so quietly
/// that a sleeping parent does not hear a cry. The app cannot raise the volume by code,
/// so the card holds the system volume slider, and the side buttons work as always.
struct VolumeWarning: View {
    let volume: Float

    private var off: Bool { volume < 0.01 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: off ? "speaker.slash.fill" : "speaker.wave.1.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.warn)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(off ? "Hlasitost iPhonu je vypnutá" : "Hlasitost iPhonu je nízká · \(Int((volume * 100).rounded())) %")
                        .font(.subheadline.weight(.semibold))
                    Text("Pláč nemusíte slyšet. Zesilte tlačítky na boku telefonu, nebo tady.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SystemVolumeSlider()
                .frame(height: 34)
                .padding(.leading, 40)
        }
        .padding(14)
        .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), tint: Theme.warn.opacity(0.16))
        .accessibilityElement(children: .contain)
    }
}

/// The system volume slider. It is the only way an app may change the iPhone's volume.
struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.tintColor = UIColor(Theme.accent)
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}
}
