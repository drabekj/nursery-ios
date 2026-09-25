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

    /// The colour of one bar of the waveform. A louder sound is warmer.
    static func level(_ v: Float) -> Color {
        switch v {
        case ..<0.35: return calm
        case ..<0.7: return middle
        default: return loud
        }
    }

    static func color(for status: NurseryActivityAttributes.Status) -> Color {
        switch status {
        case .listening: calm
        case .silent: accent
        case .connecting: warn
        case .lost: alarm
        case .muted: secondaryText
        }
    }

    static func symbol(for status: NurseryActivityAttributes.Status) -> String {
        switch status {
        case .listening: "ear.fill"
        case .silent: "bell.badge.fill"
        case .connecting: "antenna.radiowaves.left.and.right"
        case .lost: "exclamationmark.triangle.fill"
        case .muted: "speaker.slash.fill"
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

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background {
                if animated && !reduceMotion {
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
    static func firm() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}
