import Foundation

// `RoomState`, the word itself, is in Shared/NurseryActivity.swift: the Live Activity needs it too.

/// One verdict of the cry classifier, for one window of sound (about one second).
enum CryVerdict: Equatable, Sendable {
    /// The classifier said "baby cry" with this confidence (0...1).
    case cry(Float)
    /// The classifier heard something else (its label, for the log).
    case other(String, Float)
}

/// The rules that turn the signals into a `RoomState`. Pure: no clock of its own, no views.
/// Feed it at 2 Hz with `update`, and the verdicts of the classifier as they arrive.
struct RoomStateMachine: Sendable {
    /// The signals at one moment.
    struct Input: Sendable {
        /// The app hears the room now (live or muted).
        var heard: Bool
        /// The app has heard the room at least once since the start.
        var everHeard: Bool
        /// A sound event runs (`SoundActivity.current != nil`).
        var eventRunning: Bool
        /// Seconds of the running event, 0 without one.
        var eventSeconds: TimeInterval = 0
        /// The peak level of the running event, 0...1.
        var eventPeak: Float = 0
        /// The smoothed level now, 0...1.
        var level: Float = 0
        /// The level that counts as loud, from the noise floor.
        var loudLevel: Float = 0.45
        /// The classifier can run (a model is loaded). Without one the loudness rule decides.
        var classifierAvailable: Bool
    }

    /// The classifier must say "cry" with at least this confidence.
    var cryConfidence: Float = 0.5
    /// ...in at least this many of the last `windowCount` verdicts.
    var cryVotes = 2
    var windowCount = 3
    /// "Pláče" stays at least this long, so the pauses of a crying baby do not flip the word...
    var cryHold: TimeInterval = 15
    /// ...and it ends this long after the last cry verdict.
    var cryRelease: TimeInterval = 10
    /// "Nehlídá" after this long without sound. The same time as the loss notification.
    var lostAfter: TimeInterval = 20
    /// The loudness rule without a classifier: this many loud seconds within `loudWindow`...
    var loudSeconds: TimeInterval = 6
    var loudWindow: TimeInterval = 12
    /// ...or an event this long with a peak this high. The same rule as `SoundActivity.Episode.kind`.
    var longEvent: TimeInterval = 12
    var loudPeak: Float = 0.78

    private(set) var state: RoomState = .connecting
    /// When the state last changed.
    private(set) var since: Date?
    /// The last verdicts, newest last. Cleared when the event ends.
    private(set) var verdicts: [CryVerdict] = []
    private var lostSince: Date?
    private var lastCry: Date?
    private var loudTicks: [Date] = []

    /// A verdict of the classifier. It counts only while a sound event runs.
    mutating func classified(_ verdict: CryVerdict) {
        verdicts.append(verdict)
        if verdicts.count > windowCount { verdicts.removeFirst(verdicts.count - windowCount) }
    }

    /// The signals at `now`. Returns the state, changed or not.
    @discardableResult
    mutating func update(_ input: Input, now: Date) -> RoomState {
        let next: RoomState
        if !input.heard {
            if !input.everHeard {
                next = .connecting
            } else {
                if lostSince == nil { lostSince = now }
                let lostFor = now.timeIntervalSince(lostSince ?? now)
                // The last state stays for the first seconds of a gap. A ribbon says "Připojuji…".
                next = lostFor >= lostAfter ? .lost : (state == .connecting ? .connecting : state)
            }
        } else {
            lostSince = nil
            if input.eventRunning {
                trackLoud(input, now: now)
                let crying = input.classifierAvailable ? cryByClassifier() : cryByLoudness(input, now: now)
                if crying { lastCry = now }
                if state == .cry, let since, let lastCry {
                    let holding = now.timeIntervalSince(since) < cryHold || now.timeIntervalSince(lastCry) < cryRelease
                    next = crying || holding ? .cry : .sound
                } else {
                    next = crying ? .cry : .sound
                }
            } else {
                verdicts = []
                loudTicks = []
                lastCry = nil
                next = .calm
            }
        }
        if next != state {
            state = next
            since = now
        }
        return state
    }

    private func cryByClassifier() -> Bool {
        let votes = verdicts.filter { if case .cry(let c) = $0 { return c >= cryConfidence }; return false }.count
        return votes >= cryVotes
    }

    private mutating func trackLoud(_ input: Input, now: Date) {
        if input.level >= input.loudLevel { loudTicks.append(now) }
        loudTicks.removeAll { now.timeIntervalSince($0) > loudWindow }
    }

    private func cryByLoudness(_ input: Input, now: Date) -> Bool {
        // The ticks come at 2 Hz: each one is half a second of loud sound.
        let loud = Double(loudTicks.count) * 0.5 >= loudSeconds
        let long = input.eventSeconds >= longEvent && input.eventPeak >= loudPeak
        return loud || long
    }
}
