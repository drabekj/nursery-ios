import SwiftUI
import UIKit

// The state of the room, readable from across the room. Four layers, by distance:
// - 4 m: the colour of the field (the whole background of the glance view).
// - 2–3 m: the silhouette of the glyph: a ring (Klid, Nehlídá), bare bars (Ozývá se),
//   a solid disc (Pláče). The silhouettes differ, so the state reads also without colour
//   and with Reduce Motion.
// - 1–1.5 m: the word, 96 pt.
// - arm's length: the subline, the ribbon, the cards.
//
// The field follows `engine.roomState` (2 Hz, changes only when the state changes). Only the
// ripples of "Ozývá se" watch the 10 Hz meter, and only while that glyph is on screen.

// MARK: - The words

@MainActor
enum StateText {
    /// A modifier of the state. It never changes the field colour.
    struct Ribbon: Equatable {
        let symbol: String
        let text: String
    }

    /// "42 s", "12 min", "1 h 5 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(Int(seconds), 0)
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        let m = s % 3600 / 60
        return m == 0 ? "\(s / 3600) h" : "\(s / 3600) h \(m) min"
    }

    /// The loudness word, lower-case. A sound now is at least "slabé zvuky".
    private static func level(_ e: MonitorEngine) -> String {
        max(e.roomLevel, RoomLevel.some).title.lowercased()
    }

    /// The line under the word. No first person: "zkouší se znovu", not "zkouším".
    static func subline(_ e: MonitorEngine, source: Settings.Source, now: Date = Date()) -> String {
        switch e.roomState {
        case .connecting:
            return source == .phone ? "hledám telefon u miminka" : "hledám kameru"
        case .calm:
            // The quiet counts from the end of the last sound, or from the start of the calm.
            let quiet = now.timeIntervalSince(e.lastEventEnd ?? e.roomStateSince)
            var text = e.lastEventEnd == nil ? "ticho od začátku" : "ticho už \(duration(quiet))"
            // "Spí" would be a lie: the app does not know. After 15 min of quiet it is a fair guess.
            if quiet >= 15 * 60 { text += " · nejspíš spí" }
            return text
        case .sound:
            return level(e)
        case .cry:
            return "\(level(e)) · už \(duration(now.timeIntervalSince(e.roomStateSince)))"
        case .lost:
            // "Nehlídá" comes 20 s after the last sound. The sound dropped then, not now.
            let dropped = e.roomStateSince.addingTimeInterval(-20)
            return "spojení vypadlo před \(duration(now.timeIntervalSince(dropped))) · zkouší se znovu"
        }
    }

    /// Volume low wins over muted. A short gap in the sound keeps the last state and says so.
    static func ribbon(_ e: MonitorEngine) -> Ribbon? {
        switch e.roomState {
        case .lost, .connecting: return nil
        case .calm, .sound, .cry: break
        }
        if e.volumeLow {
            return Ribbon(symbol: "speaker.wave.1.fill",
                          text: "Hlasitost telefonu \(Int((e.systemVolume * 100).rounded())) % · pláč neuslyšíte")
        }
        if e.mode == .off {
            return Ribbon(symbol: "speaker.slash.fill", text: "Ztlumeno · při pláči přijde upozornění")
        }
        if e.soundStatus != .listening && e.soundStatus != .silent {
            return Ribbon(symbol: "antenna.radiowaves.left.and.right", text: "Připojuji…")
        }
        return nil
    }

    /// One label for the whole field: "Stav: klid, ticho už 42 min".
    static func accessibility(_ e: MonitorEngine, source: Settings.Source) -> String {
        "Stav: \(e.roomState.title.lowercased()), \(subline(e, source: source))"
    }
}

// MARK: - The glyph

/// The glyph of a state, with its silhouette:
/// - Klid: the moon in a hollow ring (stroke 6 pt, fill 22 %). It breathes (10 s).
/// - Ozývá se: bare waveform bars, no circle. Ripples of the sound light the bars from inside.
/// - Pláče: a solid disc with the waveform cut out, so the field shows through. It pulses (1.2 s).
/// - Nehlídá: a hollow ring with a red wifi glyph. Static.
/// - Připojuji…: the antenna. Static.
struct StateGlyph: View {
    let state: RoomState
    /// The diameter of the ring. The disc is 15 % bigger (160 → 184), the bare glyphs about 62 %.
    var diameter: CGFloat = 160
    /// White or ink on a field, the night accent on black.
    var color: Color = .white
    /// The breath, the ripples, the pulse. Reduce Motion turns them off in any case.
    var motion = true
    /// The meter for the ripples of "Ozývá se". Nil: no ripples.
    var levels: LevelMeter?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var moving: Bool { motion && !reduceMotion }
    private var slot: CGFloat { diameter * 1.15 }

    var body: some View {
        ZStack {
            switch state {
            case .calm:
                ring(symbol: "moon.zzz.fill", symbolColor: color)
                    .modifier(Breath(on: moving))
            case .lost:
                ring(symbol: "wifi.exclamationmark", symbolColor: Theme.lostGlyph)
            case .sound:
                bars
            case .cry:
                CryDisc(diameter: slot, color: color, pulse: moving)
            case .connecting:
                Image(systemName: Theme.symbol(for: .connecting))
                    .font(.system(size: diameter * 0.55, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        // One slot for every state, so the word under it does not jump when the state changes.
        .frame(width: slot, height: slot)
        .transition(.opacity)
        .accessibilityHidden(true)
    }

    private func ring(symbol: String, symbolColor: Color) -> some View {
        ZStack {
            Circle().fill(color.opacity(0.22))
            Circle().strokeBorder(color, lineWidth: max(2, diameter * 6 / 160))
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.42, weight: .semibold))
                .foregroundStyle(symbolColor)
        }
        .frame(width: diameter, height: diameter)
    }

    private var bars: some View {
        let size = diameter * 0.625
        let ripples = moving && levels != nil
        return Image(systemName: "waveform")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color.opacity(ripples ? 0.55 : 1))
            .overlay {
                if ripples, let levels {
                    // The ripples stay inside the bars: the glyph is the mask.
                    RippleFill(levels: levels, color: color)
                        .mask {
                            Image(systemName: "waveform").font(.system(size: size, weight: .semibold))
                        }
                }
            }
    }
}

/// The 10 s breath of the Klid glyph: 5 s in, 5 s out, ±3 %.
private struct Breath: ViewModifier {
    let on: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if on {
            content.phaseAnimator([false, true]) { view, inhale in
                view.scaleEffect(inhale ? 1.035 : 0.975)
            } animation: { _ in .easeInOut(duration: 5) }
        } else {
            content
        }
    }
}

/// Three rings of the sound: now in the middle, 0.4 s and 0.8 s ago further out.
/// Only this small view watches the meter.
private struct RippleFill: View {
    @ObservedObject var levels: LevelMeter
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let h = levels.history
            let r = max(size.width, size.height) / 2
            let rings: [(ago: Int, scale: CGFloat, opacity: Double)] = [(8, 1, 0.45), (4, 0.75, 0.75), (0, 0.5, 1)]
            for ring in rings {
                let v = h.count > ring.ago ? CGFloat(h[h.count - 1 - ring.ago]) : 0
                let radius = r * ring.scale * (0.3 + 0.7 * v)
                let rect = CGRect(x: size.width / 2 - radius, y: size.height / 2 - radius, width: radius * 2, height: radius * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(ring.opacity)))
            }
        }
    }
}

/// The disc of "Pláče". The waveform is cut out of it, so it shows the field colour.
/// The pulse is a scale on the disc only: the compositor draws it, the layout does not change.
private struct CryDisc: View {
    let diameter: CGFloat
    let color: Color
    let pulse: Bool
    @State private var big = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .overlay {
                Image(systemName: "waveform")
                    .font(.system(size: diameter * 0.46, weight: .bold))
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            .scaleEffect(big ? 1.06 : 1)
            .animation(big ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .easeOut(duration: 0.3), value: big)
            .onAppear { big = pulse }
            .onChange(of: pulse) { _, on in big = on }
            .onDisappear { big = false }          // Nothing animates off screen.
    }
}

// MARK: - The field

/// The field: one static radial gradient per state, the core 8 % lighter at 40 % of the height.
/// Drawn once. A state change cross-fades it in 0.6 s; nothing else animates it.
struct StateFieldBackground: View {
    let state: RoomState
    let dim: Bool

    var body: some View {
        ZStack {
            GeometryReader { g in
                RadialGradient(colors: [Theme.fieldCore(for: state, dim: dim), Theme.field(for: state, dim: dim)],
                               center: UnitPoint(x: 0.5, y: 0.4),
                               startRadius: 0, endRadius: max(g.size.width, g.size.height) * 0.7)
            }
            .id("\(state.rawValue)-\(dim)")
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.6), value: state)
        .animation(.easeInOut(duration: 0.6), value: dim)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The subline. It counts seconds ("už 38 s"), so it redraws once a second, and only this text.
struct StateSubline: View {
    @EnvironmentObject private var engine: MonitorEngine
    @EnvironmentObject private var settings: Settings
    let color: Color
    var font: Font = .body

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(StateText.subline(engine, source: settings.source, now: context.date))
                .font(font.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(2)
        }
    }
}

/// Muted, volume low, a short gap: slate with white type (5.4:1), under the word.
struct StateRibbon: View {
    let ribbon: StateText.Ribbon

    var body: some View {
        Label(ribbon.text, systemImage: ribbon.symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.ribbon, in: Capsule())
    }
}

/// The glance view: glyph, word, subline, ribbon. The field itself is drawn behind the page
/// (`StateFieldBackground`), edge to edge; this view is only what sits on it.
struct StateField: View {
    @EnvironmentObject private var engine: MonitorEngine
    @EnvironmentObject private var settings: Settings
    /// The dark appearance or auto-dim: the dark tokens, white type.
    let dim: Bool
    /// False when the view is not on screen or in Night mode.
    var motion = true
    /// Landscape: less height, a smaller glyph.
    var compact = false
    @Environment(\.dynamicTypeSize) private var typeSize

    /// 160 pt ring (184 pt disc); 120 pt at most at the largest text sizes and in landscape.
    private var diameter: CGFloat {
        if compact { return 80 }
        return typeSize >= .accessibility3 ? 104 : 160
    }

    var body: some View {
        let state = engine.roomState
        let on = Theme.onField(for: state, dim: dim)
        VStack(spacing: 22) {
            VStack(spacing: 22) {
                // At the largest text sizes the glyph gives the space to the text.
                StateGlyph(state: state, diameter: diameter, color: on, motion: motion, levels: engine.levels)
                    .id(state)
                VStack(spacing: 6) {
                    Text(state.title)
                        .font(.system(size: 96, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.66)
                        .lineLimit(1)
                        .foregroundStyle(on)
                        .contentTransition(.opacity)
                    StateSubline(color: Theme.onFieldSecondary(for: state, dim: dim))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(StateText.accessibility(engine, source: settings.source))
            .accessibilityAddTraits(.isHeader)

            if let ribbon = StateText.ribbon(engine) {
                StateRibbon(ribbon: ribbon)
                    .transition(.opacity)
            }
            if state == .lost {
                Button { engine.reconnect(why: "user asked") } label: {
                    Text("Zkusit znovu")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(on)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .glass(in: Capsule(), interactive: true)
                }
                .buttonStyle(PressScale())
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 20)
        .animation(.easeInOut(duration: 0.35), value: state)
        .animation(.easeInOut(duration: 0.3), value: StateText.ribbon(engine))
        .modifier(StateAnnouncements(state: state))
    }
}

// MARK: - The band (picture view)

/// The same state as the field, laid out across the picture view: 96 pt tall, filled with the
/// state colour; glyph 44 pt, word 40 pt, subline. The ribbon goes under it.
struct StateBand: View {
    @EnvironmentObject private var engine: MonitorEngine
    @EnvironmentObject private var settings: Settings
    let dim: Bool
    var motion = true

    var body: some View {
        let state = engine.roomState
        let on = Theme.onField(for: state, dim: dim)
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                StateGlyph(state: state, diameter: 40, color: on, motion: motion, levels: engine.levels)
                    .id(state)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .foregroundStyle(on)
                        .contentTransition(.opacity)
                    StateSubline(color: Theme.onFieldSecondary(for: state, dim: dim), font: .subheadline)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .background {
                ZStack {
                    shape.fill(Theme.field(for: state, dim: dim))
                        .id("\(state.rawValue)-\(dim)")
                        .transition(.opacity)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(StateText.accessibility(engine, source: settings.source))
            .accessibilityAddTraits(.isHeader)

            if let ribbon = StateText.ribbon(engine) {
                StateRibbon(ribbon: ribbon)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: state)
        .animation(.easeInOut(duration: 0.3), value: StateText.ribbon(engine))
        .modifier(StateAnnouncements(state: state))
    }
}

// MARK: - The pill (full screen)

/// Full screen: a coloured pill bottom-left with the glyph, the word and the waveform.
/// It stays when the other controls hide: the state is the one thing the parent must always see.
struct StatePill: View {
    @EnvironmentObject private var engine: MonitorEngine
    @EnvironmentObject private var settings: Settings

    var body: some View {
        let state = engine.roomState
        // The full screen is always dark: the dark tokens.
        let on = Theme.onField(for: state, dim: true)
        HStack(spacing: 10) {
            StateGlyph(state: state, diameter: 26, color: on, motion: false)
            Text(state.title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(on)
                .lineLimit(1)
                .fixedSize()
            LiveWaveform(levels: engine.levels, last: 30,
                         dim: engine.soundStatus != .listening && engine.soundStatus != .silent, tint: on)
                .frame(width: 110, height: 30)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.field(for: state, dim: true), in: Capsule())
        .animation(.easeInOut(duration: 0.35), value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StateText.accessibility(engine, source: settings.source))
        .modifier(StateAnnouncements(state: state))
    }
}

// MARK: - Auto-dim

/// After 30 s untouched the field takes the dark tokens: by day the lamp is bright, at night a
/// sigh never doubles the light in the room. Only a touch or "Pláče" brings the bright field back.
@MainActor
final class FieldDimmer: ObservableObject {
    @Published private(set) var dimmed = false
    private var task: Task<Void, Never>?
    private var crying = false
    private var lastTouch = Date.distantPast

    /// A touch anywhere on the monitor.
    func touch() {
        if dimmed { withAnimation(.easeOut(duration: 0.3)) { dimmed = false } }
        // Each move of a finger calls this: start the timer again at most once a second.
        guard Date().timeIntervalSince(lastTouch) > 1 else { return }
        lastTouch = Date()
        restart()
    }

    func state(_ s: RoomState) {
        crying = s == .cry
        if crying {
            if dimmed { withAnimation(.easeOut(duration: 0.3)) { dimmed = false } }
            task?.cancel()
        } else if task == nil || task?.isCancelled == true {
            restart()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func restart() {
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, !self.crying else { return }
            withAnimation(.easeInOut(duration: 1.5)) { self.dimmed = true }
        }
    }
}

// MARK: - VoiceOver

/// VoiceOver says only the changes that matter: "Pláče", "Nehlídá", and the calm after them.
/// Not each sigh ("Ozývá se"): that would talk all night.
struct StateAnnouncements: ViewModifier {
    let state: RoomState

    func body(content: Content) -> some View {
        content.onChange(of: state) { old, new in
            guard let text = Self.announcement(from: old, to: new) else { return }
            AccessibilityNotification.Announcement(text).post()
        }
    }

    static func announcement(from old: RoomState, to new: RoomState) -> String? {
        switch new {
        case .cry: return "Pláče"
        case .lost: return "Nehlídá. Spojení vypadlo."
        case .calm where old == .cry || old == .lost: return "Klid"
        default: return nil
        }
    }
}
