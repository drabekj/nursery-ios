import Foundation

/// The sound events of the room. It answers the first question after a shower or a nap:
/// "Did the baby make a sound while I was away?"
///
/// A sound event starts when the level stays above the threshold for 1 s.
/// It ends after 4 s below the threshold. The app keeps the events of the last 24 hours.
@MainActor
final class SoundActivity: ObservableObject {
    struct Event: Codable, Identifiable, Hashable {
        var id = UUID()
        var start: Date
        var end: Date
        var peak: Float
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    struct Minute: Identifiable, Hashable {
        let start: Date
        let peak: Float
        var id: Date { start }
    }

    @Published private(set) var events: [Event] = []          // Oldest first.
    @Published private(set) var current: Event?               // A sound now.
    @Published private(set) var minutes: [Minute] = []        // The last 60 minutes.

    /// It runs when a sound event starts.
    var onEventStart: ((Event) -> Void)?
    /// 0...1, on the same scale as the level.
    var threshold: Float = 0.5

    private var aboveSince: Date?
    private var belowSince: Date?
    private var minutePeaks: [Date: Float] = [:]
    private var lastPublish = Date.distantPast
    private let storeKey = "soundEvents"

    init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let saved = try? JSONDecoder().decode([Event].self, from: data) {
            events = saved.filter { $0.end > Date().addingTimeInterval(-86_400) }
        }
    }

    var lastSound: Date? { current != nil ? Date() : events.last?.end }

    var todayEvents: [Event] {
        let start = Calendar.current.startOfDay(for: Date())
        return events.filter { $0.end >= start }
    }

    func feed(level: Float, at now: Date = Date()) {
        let minute = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60)
        minutePeaks[minute] = max(minutePeaks[minute] ?? 0, level)

        if level >= threshold {
            belowSince = nil
            if var event = current {
                event.end = now
                event.peak = max(event.peak, level)
                current = event
            } else {
                if aboveSince == nil { aboveSince = now }
                if let since = aboveSince, now.timeIntervalSince(since) >= 1 {
                    let event = Event(start: since, end: now, peak: level)
                    current = event
                    onEventStart?(event)
                }
            }
        } else {
            aboveSince = nil
            if let event = current {
                if belowSince == nil { belowSince = now }
                if let since = belowSince, now.timeIntervalSince(since) >= 4 {
                    finish(event)
                }
            }
        }

        if now.timeIntervalSince(lastPublish) >= 1 {
            lastPublish = now
            publishMinutes(now: now)
        }
    }

    /// It ends an event in progress, for example when the sound goes off.
    func interrupt() {
        aboveSince = nil
        if let current { finish(current) }
    }

    func clear() {
        events = []
        current = nil
        minutePeaks = [:]
        minutes = []
        save()
    }

    private func finish(_ event: Event) {
        current = nil
        belowSince = nil
        events.append(event)
        let cutoff = Date().addingTimeInterval(-86_400)
        events.removeAll { $0.end < cutoff }
        save()
    }

    private func publishMinutes(now: Date) {
        let start = now.addingTimeInterval(-3600)
        minutePeaks = minutePeaks.filter { $0.key >= start }
        minutes = minutePeaks.map { Minute(start: $0.key, peak: $0.value) }.sorted { $0.start < $1.start }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(events) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    // MARK: Demo data, for the screenshots

    func loadDemo(now: Date = Date()) {
        let offsets: [(TimeInterval, TimeInterval, Float)] = [(-3000, 14, 0.72), (-2100, 6, 0.58), (-1260, 38, 0.91), (-420, 9, 0.63)]
        events = offsets.map { Event(start: now.addingTimeInterval($0.0), end: now.addingTimeInterval($0.0 + $0.1), peak: $0.2) }
        for m in 0..<60 {
            let t = now.addingTimeInterval(Double(-60 * (59 - m)))
            let key = Date(timeIntervalSince1970: floor(t.timeIntervalSince1970 / 60) * 60)
            var peak = Float(0.12 + 0.08 * sin(Double(m) * 0.7))
            for e in events where abs(e.start.timeIntervalSince(t)) < 60 { peak = e.peak }
            minutePeaks[key] = peak
        }
        publishMinutes(now: now)
    }
}
