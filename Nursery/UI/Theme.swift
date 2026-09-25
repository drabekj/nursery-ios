import SwiftUI
import UIKit

/// A night palette. The screen is often the only light in a dark bedroom,
/// so the colours are dim, warm, and calm. Red means a fault, never a normal state.
enum Theme {
    static let skyTop = Color(red: 0.035, green: 0.055, blue: 0.12)
    static let skyBottom = Color(red: 0.07, green: 0.09, blue: 0.19)
    static let card = Color.white.opacity(0.055)
    static let cardStroke = Color.white.opacity(0.08)
    static let moon = Color(red: 0.97, green: 0.85, blue: 0.55)       // The accent. Warm moonlight.
    static let calm = Color(red: 0.45, green: 0.89, blue: 0.72)       // Live, listening.
    static let warn = Color(red: 1.0, green: 0.72, blue: 0.38)        // Connecting.
    static let alarm = Color(red: 1.0, green: 0.42, blue: 0.42)       // The sound is lost.
    static let secondaryText = Color.white.opacity(0.6)

    static var background: some View {
        LinearGradient(colors: [skyTop, skyBottom], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
    }

    /// The colour of one bar of the waveform. A louder sound is warmer.
    static func level(_ v: Float) -> Color {
        switch v {
        case ..<0.35: return calm
        case ..<0.7: return moon
        default: return Color(red: 1.0, green: 0.6, blue: 0.45)
        }
    }

    static func color(for status: NurseryActivityAttributes.Status) -> Color {
        switch status {
        case .listening: calm
        case .connecting: warn
        case .lost: alarm
        case .muted: secondaryText
        }
    }

    static func symbol(for status: NurseryActivityAttributes.Status) -> String {
        switch status {
        case .listening: "ear.fill"
        case .connecting: "antenna.radiowaves.left.and.right"
        case .lost: "exclamationmark.triangle.fill"
        case .muted: "speaker.slash.fill"
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
    var tint: Color = .white
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12)))
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
