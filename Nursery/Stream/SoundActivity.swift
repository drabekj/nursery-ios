import Foundation
import UIKit

/// What happened in the room. It answers the first question after a shower or a night:
/// "Was the baby quiet, and was Chůvička listening at all?"
///
/// Three ideas keep it honest and easy to read:
/// - The threshold adapts to the room. The app follows the noise floor (the hiss of the camera,
///   a fan) and counts only sounds clearly above it. A fixed level gave false events in a noisy room.
/// - Sounds close together form one episode. One cry of 4 minutes is one row, not fifteen.
/// - The app records when it listened. A quiet stretch then means quiet, not "the app was off".
@MainActor
final class SoundActivity: ObservableObject {
    struct Event: Codable, Identifiable, Hashable {
        var id = UUID()
        var start: Date
        var end: Date
        var peak: Float
        /// The room word was "Pláče" during this event (the classifier, or the loudness rule without it).
        var cried = false
        /// The cry classifier gave at least one verdict during this event.
        var classified = false
        var duration: TimeInterval { end.timeIntervalSince(start) }

        enum CodingKeys: String, CodingKey { case id, start, end, peak, cried, classified }
    }

    /// A span of time when the app listened to the room.
    struct Span: Codable, Hashable {
        var start: Date
        var end: Date
    }

    /// Sounds less than 90 s apart, as one episode.
    struct Episode: Identifiable, Hashable {
        enum Kind { case fuss, cry }
        let id: UUID                // The id of its first event. The snapshot uses it.
        let start: Date
        let end: Date
        let peak: Float
        let soundSeconds: TimeInterval
        /// An event of it reached "Pláče".
        var cried = false
        /// The classifier listened to an event of it.
        var classified = false
        var duration: TimeInterval { end.timeIntervalSince(start) }
        /// Crying: the room word was "Pláče", so the live screen and the history agree. Without any
        /// verdict of the classifier (an old saved episode, or no model), the old rule decides:
        /// a long or a loud episode. Everything else is fussing.
        var kind: Kind {
            if cried { return .cry }
            if classified { return .fuss }
            return soundSeconds >= 12 || peak >= 0.78 ? .cry : .fuss
        }
        var title: String { kind == .cry ? "Pláč" : "Zafňukání" }
    }

    @Published private(set) var events: [Event] = []          // Oldest first.
    @Published private(set) var current: Event?               // A sound now.
    @Published private(set) var coverage: [Span] = []         // When the app listened.

    /// It runs when a new episode starts (not for each sound inside an episode).
    var onEpisodeStart: ((Episode) -> Void)?
    /// How far above the noise floor a sound must be. From the sensitivity setting.
    var margin: Float = 0.2

    /// The noise floor of the room, 0...1. It falls fast and rises slowly.
    private(set) var noiseFloor: Float = 0.15
    private var aboveSince: Date?
    private var belowSince: Date?
    private var lastSave = Date.distantPast
    private let eventsKey = "soundEvents.v2"
    private let coverageKey = "listeningSpans.v1"
    private static let episodeGap: TimeInterval = 90
    private static let keepFor: TimeInterval = 24 * 3600

    init() {
        let d = UserDefaults.standard
        let cutoff = Date().addingTimeInterval(-Self.keepFor)
        if let data = d.data(forKey: eventsKey), let saved = try? JSONDecoder().decode([Event].self, from: data) {
            events = saved.filter { $0.end > cutoff }
        }
        if let data = d.data(forKey: coverageKey), let saved = try? JSONDecoder().decode([Span].self, from: data) {
            coverage = saved.filter { $0.end > cutoff }
        }
    }

    // MARK: The questions the screens ask

    /// The level that counts as a sound now.
    var threshold: Float { min(0.9, max(0.3, noiseFloor + margin)) }

    var lastSound: Date? { current != nil ? Date() : events.last?.end }

    /// All episodes, newest first. An episode in progress is included.
    var episodes: [Episode] {
        var all = events
        if let current { all.append(current) }
        var result: [Episode] = []
        var group: [Event] = []
        func close() {
            guard let first = group.first, let last = group.last else { return }
            result.append(Episode(id: first.id, start: first.start, end: last.end,
                                  peak: group.map(\.peak).max() ?? 0,
                                  soundSeconds: group.reduce(0) { $0 + $1.duration },
                                  cried: group.contains { $0.cried }, classified: group.contains { $0.classified }))
            group = []
        }
        for e in all {
            if let last = group.last, e.start.timeIntervalSince(last.end) > Self.episodeGap { close() }
            group.append(e)
        }
        close()
        return result.reversed()
    }

    func episodes(since: Date) -> [Episode] { episodes.filter { $0.end >= since } }

    func coverage(since: Date) -> [Span] {
        coverage.filter { $0.end >= since }.map { Span(start: max($0.start, since), end: $0.end) }
    }

    /// Seconds of listening since a date.
    func listened(since: Date) -> TimeInterval {
        coverage(since: since).reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }

    // MARK: The input, 10 times a second while the app hears the room

    func feed(level: Float, at now: Date = Date()) {
        extendCoverage(now)

        // The noise floor: down in about 2 s, up in about 3 minutes. A cry does not raise it much.
        let rate: Float = level < noiseFloor ? 0.05 : 0.0006
        noiseFloor += (level - noiseFloor) * rate

        if level >= threshold {
            belowSince = nil
            if var event = current {
                // At most once a second, or for a louder peak: each change redraws the views that show it.
                if level > event.peak || now.timeIntervalSince(event.end) >= 1 {
                    event.end = now
                    event.peak = max(event.peak, level)
                    current = event
                }
            } else {
                if aboveSince == nil { aboveSince = now }
                if let since = aboveSince, now.timeIntervalSince(since) >= 1 {
                    let startsEpisode = events.last.map { since.timeIntervalSince($0.end) > Self.episodeGap } ?? true
                    let event = Event(start: since, end: now, peak: level)
                    current = event
                    if startsEpisode {
                        onEpisodeStart?(Episode(id: event.id, start: since, end: now, peak: level, soundSeconds: 0))
                    }
                }
            }
        } else {
            aboveSince = nil
            if let event = current {
                if belowSince == nil { belowSince = now }
                if let since = belowSince, now.timeIntervalSince(since) >= 4 { finish(event) }
            }
        }
        // Each 5 minutes: each save rewrites the whole list. The end of an event saves at once.
        if now.timeIntervalSince(lastSave) > 300 { save() }
    }

    /// The room word became "Pláče" during the sound now. Once per event: each change redraws.
    func markCurrentCried() {
        guard var event = current, !event.cried else { return }
        event.cried = true
        current = event
    }

    /// The cry classifier gave a verdict during the sound now. Once per event.
    func markCurrentClassified() {
        guard var event = current, !event.classified else { return }
        event.classified = true
        current = event
    }

    /// It ends an event in progress, for example when the sound goes off.
    func interrupt() {
        aboveSince = nil
        if let current { finish(current) }
        save()
    }

    func clear() {
        events = []
        current = nil
        coverage = []
        Moments.clear()
        save()
    }

    private func extendCoverage(_ now: Date) {
        if var last = coverage.last, now.timeIntervalSince(last.end) < 90 {
            // Move the end each 10 s, not 10 times a second. Each change redraws every chart
            // of the activity, also in the background, where that got the app killed.
            guard now.timeIntervalSince(last.end) >= 10 else { return }
            last.end = now
            coverage[coverage.count - 1] = last
        } else {
            coverage.append(Span(start: now, end: now))
        }
    }

    private func finish(_ event: Event) {
        current = nil
        belowSince = nil
        events.append(event)
        save()
    }

    private func save() {
        lastSave = Date()
        let cutoff = Date().addingTimeInterval(-Self.keepFor)
        events.removeAll { $0.end < cutoff }
        coverage.removeAll { $0.end < cutoff }
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(events) { d.set(data, forKey: eventsKey) }
        if let data = try? JSONEncoder().encode(coverage) { d.set(data, forKey: coverageKey) }
    }

    // MARK: Demo data, for the screenshots

    func loadDemo(now: Date = Date()) {
        coverage = [Span(start: now.addingTimeInterval(-9.5 * 3600), end: now.addingTimeInterval(-6.2 * 3600)),
                    Span(start: now.addingTimeInterval(-5.9 * 3600), end: now)]
        func burst(_ hoursAgo: Double, _ seconds: [Double], _ peak: Float) -> [Event] {
            var t = now.addingTimeInterval(-hoursAgo * 3600)
            return seconds.map { len in
                defer { t = t.addingTimeInterval(len + 20) }
                return Event(start: t, end: t.addingTimeInterval(len), peak: peak)
            }
        }
        events = burst(8.1, [3], 0.55) + burst(4.4, [8, 14, 22, 9], 0.9) + burst(2.0, [4, 3], 0.6) + burst(0.3, [6], 0.66)
    }
}

extension SoundActivity.Event {
    /// The events saved by 1.9 and older have no `cried` and `classified`. They decode as false,
    /// so their episodes keep the old loudness rule.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
        peak = try c.decode(Float.self, forKey: .peak)
        cried = try c.decodeIfPresent(Bool.self, forKey: .cried) ?? false
        classified = try c.decodeIfPresent(Bool.self, forKey: .classified) ?? false
    }
}

/// A photo of the cot at the start of each episode. Small JPEGs in Application Support.
enum Moments {
    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("moments", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func url(for id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).jpg") }

    /// Whether a photo exists, without reading and decoding it.
    static func exists(for id: UUID) -> Bool {
        MonitorEngine.isDemo || FileManager.default.fileExists(atPath: url(for: id).path)
    }

    static func image(for id: UUID) -> UIImage? {
        if MonitorEngine.isDemo { return UIImage(named: "DemoFrame") }
        return UIImage(contentsOfFile: url(for: id).path)
    }

    static func save(_ image: UIImage, for id: UUID) {
        let width: CGFloat = 960
        let scale = min(1, width / max(image.size.width, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let small = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = small.jpegData(compressionQuality: 0.7) else { return }
        try? data.write(to: url(for: id), options: .atomic)
        prune(keep: 40)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: dir)
    }

    private static func prune(keep: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a > b
        }
        for file in sorted.dropFirst(keep) { try? fm.removeItem(at: file) }
    }
}
