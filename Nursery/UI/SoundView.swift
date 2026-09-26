import SwiftUI
import UIKit

// The sound view ("Jen zvuk"), the glance view: the parent only listens. There is no picture,
// so the screen leaves out everything that belongs to the picture (aim, zoom, photo, the small
// window) and gives the state of the room the whole screen: the field in the state colour,
// the glyph, the word, the subline (`StateField`). Under it two glass cards for arm's length:
// the waveform and the last hour. No photo card: the field gets the space.
//
// Why a parent chooses it: it saves the battery and the Wi-Fi, the phone stays cool,
// and it reads from across the room.

// MARK: - The switch

/// "Obraz | Jen zvuk" at the top of the main screen. The pill slides to the chosen side.
struct ViewSwitch: View {
    let soundView: Bool
    /// On a state field: the field colour and the colour on it (white or ink). No brand yellow on
    /// a field: the active segment is `onField` at 90 % with the field colour as its label.
    /// Nil on the plain page: the yellow pill with dark text, as before.
    var field: Color?
    var onField: Color?
    let choose: (Bool) -> Void
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            segment(false, "video.fill", "Obraz")
            segment(true, "waveform", "Jen zvuk")
        }
        .padding(4)
        .glass(in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Zobrazení")
    }

    private func segment(_ value: Bool, _ symbol: String, _ title: String) -> some View {
        let selected = soundView == value
        return Button {
            guard !selected else { return }
            Haptics.select()
            choose(value)
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(selected ? (field ?? Color.black) : (onField ?? Color.primary))
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background {
                    if selected {
                        Capsule().fill(field == nil ? Theme.moon : (onField ?? .white).opacity(0.9))
                            .matchedGeometryEffect(id: "pill", in: ns)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - The cards

/// The waveform of the room now, 36 pt, on a glass card over the field. The bars take the colour
/// on the field (white or ink): teal bars on a teal field would not show.
struct SoundWaveCard: View {
    @EnvironmentObject private var engine: MonitorEngine
    let dim: Bool

    var body: some View {
        LiveWaveform(levels: engine.levels, dim: !RoomWords.hearsRoom(engine),
                     tint: Theme.onField(for: engine.roomState, dim: dim))
            .frame(height: 36)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
