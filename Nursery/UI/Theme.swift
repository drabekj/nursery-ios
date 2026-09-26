import SwiftUI
import UIKit

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    /// A colour with one value for light mode and one for dark mode.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

/// Two palettes. Light ("morning nursery"): a soft dawn blue-grey with a warm amber accent.
/// Dark ("night"): deep navy with warm moonlight; the screen is often the only light in a bedroom.
/// The picture area and Night mode are always dark. Red means a fault, never a normal state.
/// The state of the room has its own colours (teal, amber, wine, graphite): see `field(for:dim:)`.
enum Theme {
    static let skyTop = Color(light: 0xF6F8FC, dark: 0x090E1F)
    static let skyBottom = Color(light: 0xE9EDF6, dark: 0x121831)
    static let card = Color.primary.opacity(0.05)
    static let cardStroke = Color.primary.opacity(0.08)
    /// The fill of an active control. It stays yellow in both modes, with dark text on it.
    static let moon = Color(light: 0xF5CF6E, dark: 0xF7D98C)
    /// The tint of text, icons, and system controls. Deeper in light mode, for contrast.
    static let accent = Color(light: 0xA86B0C, dark: 0xF7D98C)
    static let calm = Color(light: 0x1C9A6C, dark: 0x73E3B8)          // Live, listening.
    static let warn = Color(light: 0xD27D12, dark: 0xFFB861)          // Connecting, a sound now.
    static let alarm = Color(light: 0xD8433D, dark: 0xFF6B6B)         // The sound is lost.
    static let loud = Color(light: 0xE0613F, dark: 0xFF9973)
    static let middle = Color(light: 0xE3A020, dark: 0xF7D98C)
    static let glowNeutral = Color(light: 0x9AA3B8, dark: 0x5A6070)
    static let secondaryText = Color.secondary

    static var background: some View {
        LinearGradient(colors: [skyTop, skyBottom], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
    }

    /// The colour of one bar of the waveform: teal, amber, wine, the same hues as the state fields.
    /// So the waveform and the field agree.
    static func level(_ v: Float) -> Color {
        switch v {
        case ..<0.35: return stateCalm
        case ..<0.7: return stateSound
        default: return stateCry
        }
    }

    // MARK: The state of the room

    // One colour per state. The field is the whole background of the glance view, the band in the
    // picture view, the frame of the video. Red (`alarm`) stays for a fault: the cry is wine.
    // Light: the bright set, for a lit room. Dark appearance and auto-dim: a darker set with white
    // type on all fields, so a sigh at night never doubles the light in the room.

    /// The state hues on a page without a field (waveform bars, the hour strip, marks).
    static let stateCalm = Color(light: 0x00A1A0, dark: 0x2BB5B3)
    static let stateSound = Color(light: 0xE8A92A, dark: 0xFBC040)
    static let stateCry = Color(light: 0xA81233, dark: 0xC64B70)
    /// Dark type on the amber field. White there is about 2:1, ink is 10:1.
    static let ink = Color(uiColor: UIColor(hex: 0x1B1B1F))
    /// The ribbon under the word: muted, volume low, a short gap. Never a field colour.
    static let ribbon = Color(uiColor: UIColor(hex: 0x5C6B8A))
    /// The wifi glyph of "Nehlídá": the dark-mode alarm red, 4:1 on graphite.
    static let lostGlyph = Color(uiColor: UIColor(hex: 0xFF6B6B))

    private static func fieldHex(_ state: RoomState, dim: Bool) -> UInt32 {
        switch state {
        case .calm: dim ? 0x117376 : 0x00A1A0
        case .sound: dim ? 0x78662E : 0xFBC040
        case .cry: dim ? 0x570F29 : 0xA81233
        case .lost, .connecting: dim ? 0x2A2C33 : 0x3A3D45
        }
    }

    /// The field colour of a state. `dim` is true in the dark appearance and after auto-dim.
    /// Not a dynamic colour on purpose: the views on a field override the colour scheme
    /// (white type = dark scheme), and the field must not follow that.
    static func field(for state: RoomState, dim: Bool) -> Color {
        Color(uiColor: UIColor(hex: fieldHex(state, dim: dim)))
    }

    /// The core of the field: 8 % lighter. The field is one static radial gradient from it.
    static func fieldCore(for state: RoomState, dim: Bool) -> Color {
        let hex = fieldHex(state, dim: dim)
        func up(_ c: UInt32) -> CGFloat { let v = CGFloat(c & 0xFF) / 255; return v + (1 - v) * 0.08 }
        return Color(uiColor: UIColor(red: up(hex >> 16), green: up(hex >> 8), blue: up(hex), alpha: 1))
    }

    /// True when the type on the field is dark (only the bright amber). The status bar and the
    /// colour scheme of the controls on the field follow it.
    static func fieldIsLight(_ state: RoomState, dim: Bool) -> Bool { state == .sound && !dim }

    /// The glyph, the word and the labels on a field: white, or ink on the bright amber.
    static func onField(for state: RoomState, dim: Bool = false) -> Color {
        fieldIsLight(state, dim: dim) ? ink : .white
    }

    /// Small text on a field: white 90 %, ink 70 % on amber. About 4.5:1.
    static func onFieldSecondary(for state: RoomState, dim: Bool = false) -> Color {
        fieldIsLight(state, dim: dim) ? ink.opacity(0.7) : .white.opacity(0.9)
    }

    /// The state colour on black, for Night mode. The cry is a lighter wine there, else it is lost in black.
    static func nightAccent(for state: RoomState) -> Color {
        switch state {
        case .calm: Color(uiColor: UIColor(hex: 0x00A1A0))
        case .sound: Color(uiColor: UIColor(hex: 0xFBC040))
        case .cry: Color(uiColor: UIColor(hex: 0xC64B70))
        case .lost: lostGlyph
        case .connecting: .white
        }
    }

    /// The glyph of a state. The silhouette around it (ring, bare bars, disc) is in `StateGlyph`.
    static func symbol(for state: RoomState) -> String {
        switch state {
        case .connecting: "antenna.radiowaves.left.and.right"
        case .calm: "moon.zzz.fill"
        case .sound, .cry: "waveform"
        case .lost: "wifi.exclamationmark"
        }
    }

    static func color(for status: NurseryActivityAttributes.Status) -> Color {
        switch status {
        case .listening: calm
        case .silent: accent
        case .connecting: warn
        case .lost: alarm
        }
    }

    static func symbol(for status: NurseryActivityAttributes.Status) -> String {
        switch status {
        case .listening: "ear.fill"
        case .silent: "bell.badge.fill"
        case .connecting: "antenna.radiowaves.left.and.right"
        case .lost: "exclamationmark.triangle.fill"
        }
    }
}

/// The loudness of the room in words. The engine holds a word for a moment before it changes,
/// so the large headline does not flicker with each syllable.
enum RoomLevel: Int, Comparable {
    case quiet, some, loud, veryLoud

    init(_ v: Float) {
        switch v {
        case ..<0.15: self = .quiet
        case ..<0.45: self = .some
        case ..<0.75: self = .loud
        default: self = .veryLoud
        }
    }

    /// A typical level for the word, for a glow that follows the words, not each 0.1 s tick.
    var value: Float {
        switch self {
        case .quiet: 0.05
        case .some: 0.3
        case .loud: 0.6
        case .veryLoud: 0.9
        }
    }

    var title: String {
        switch self {
        case .quiet: "Ticho"
        case .some: "Slabé zvuky"
        case .loud: "Hlasitý zvuk"
        case .veryLoud: "Velmi hlasitý zvuk"
        }
    }

    static func < (a: RoomLevel, b: RoomLevel) -> Bool { a.rawValue < b.rawValue }
}

/// A dot that stays at full colour, with a soft ring that grows and fades.
/// The loop runs in its own phase animator, so it never animates the views around it.
struct PulseDot: View {
    let color: Color
    var size: CGFloat = 8
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// It pulses for some seconds after it appears or changes, then it stays still. A pulse that
    /// never stops keeps SwiftUI drawing 60 frames a second for the whole night.
    @State private var pulsing = true

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background {
                if animated && !reduceMotion && pulsing {
                    Circle()
                        .stroke(color, lineWidth: 1.5)
                        .phaseAnimator([false, true]) { ring, grown in
                            ring.scaleEffect(grown ? 2.4 : 1).opacity(grown ? 0 : 0.7)
                        } animation: { grown in
                            grown ? .easeOut(duration: 1.4) : nil
                        }
                }
            }
            .accessibilityHidden(true)
            .task(id: animated) {
                pulsing = true
                try? await Task.sleep(for: .seconds(8))
                pulsing = false
            }
    }
}

extension Font {
    static func rounded(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        .system(style, design: .rounded).weight(weight)
    }
}

/// A card with a soft glass edge.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.cardStroke))
    }
}

/// A round glass button for the controls on top of the picture and in the header.
struct GlassCircleButton: View {
    let symbol: String
    var size: CGFloat = 40
    var tint: Color = .primary
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .glass(in: Circle(), interactive: true)
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
    }
}

/// A button that shrinks a little when pressed. The eye sees the press at once.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
    static func firm() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}
