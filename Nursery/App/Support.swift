import Combine
import Foundation
import os
import UIKit

/// The last 200 events, for the diagnosis screen. The telephone gives no console,
/// so this list is the only way to see why the sound stopped at 3 a.m.
final class Log: ObservableObject, @unchecked Sendable {
    static let shared = Log()
    struct Entry: Identifiable { let id = UUID(); let time: Date; let text: String }

    @Published private(set) var entries: [Entry] = []
    private let logger = Logger(subsystem: "cz.drabek.nursery", category: "monitor")

    func add(_ text: String) {
        logger.info("\(text, privacy: .public)")
        let entry = Entry(time: Date(), text: text)
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > 200 { self.entries.removeFirst(self.entries.count - 200) }
        }
    }

    var text: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return entries.map { "\(f.string(from: $0.time))  \($0.text)" }.joined(separator: "\n")
    }
}

/// The settings. The defaults work on the home Wi-Fi with no setup.
final class Settings: ObservableObject {
    enum Loudness: String, CaseIterable, Identifiable {
        case normal, loud, max
        var id: String { rawValue }
        var title: String { switch self { case .normal: "Normal"; case .loud: "Loud"; case .max: "Max" } }
        var decibels: Float { switch self { case .normal: 0; case .loud: 12; case .max: 20 } }
    }

    /// The level at which a sound counts as an event, for the activity and the alerts.
    enum Sensitivity: String, CaseIterable, Identifiable {
        case low, medium, high
        var id: String { rawValue }
        var title: String { switch self { case .low: "Only loud crying"; case .medium: "Crying and fussing"; case .high: "Every small sound" } }
        var threshold: Float { switch self { case .low: 0.68; case .medium: 0.52; case .high: 0.38 } }
    }

    enum Quality: String, CaseIterable, Identifiable {
        case high, low
        var id: String { rawValue }
        var title: String { switch self { case .high: "2K (sharp zoom)"; case .low: "360p (saves battery)" } }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case light, dark, automatic
        var id: String { rawValue }
        var title: String { switch self { case .light: "Light"; case .dark: "Dark"; case .automatic: "Automatic" } }
    }

    private let d = UserDefaults.standard

    @Published var host: String { didSet { d.set(host, forKey: "host") } }
    @Published var quality: Quality { didSet { d.set(quality.rawValue, forKey: "quality") } }
    @Published var loudness: Loudness { didSet { d.set(loudness.rawValue, forKey: "loudness") } }
    @Published var keepAwake: Bool { didSet { d.set(keepAwake, forKey: "keepAwake") } }
    @Published var liveActivity: Bool { didSet { d.set(liveActivity, forKey: "liveActivity") } }
    @Published var alertOnLoss: Bool { didSet { d.set(alertOnLoss, forKey: "alertOnLoss") } }
    @Published var alertOnSound: Bool { didSet { d.set(alertOnSound, forKey: "alertOnSound") } }
    @Published var sensitivity: Sensitivity { didSet { d.set(sensitivity.rawValue, forKey: "sensitivity") } }
    @Published var appearance: Appearance { didSet { d.set(appearance.rawValue, forKey: "appearance") } }

    init() {
        host = d.string(forKey: "host") ?? "192.168.0.136"
        quality = Quality(rawValue: d.string(forKey: "quality") ?? "") ?? .high
        loudness = Loudness(rawValue: d.string(forKey: "loudness") ?? "") ?? .normal
        keepAwake = d.object(forKey: "keepAwake") as? Bool ?? true
        liveActivity = d.object(forKey: "liveActivity") as? Bool ?? true
        alertOnLoss = d.object(forKey: "alertOnLoss") as? Bool ?? true
        alertOnSound = d.object(forKey: "alertOnSound") as? Bool ?? false
        sensitivity = Sensitivity(rawValue: d.string(forKey: "sensitivity") ?? "") ?? .medium
        appearance = Appearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .light
    }

    var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The go2rtc RTSP restream. The query "?audio" asks go2rtc for the sound only.
    func streamURL(audioOnly: Bool) -> String {
        let name = quality == .high ? "nursery" : "nursery_sd"
        return "rtsp://\(trimmedHost):8554/\(name)" + (audioOnly ? "?audio" : "")
    }
}

/// The pan, the tilt, and the power, through the Home Assistant webhooks.
/// The webhook ids come from the config file that go2rtc already serves on the LAN.
/// Thus no id is in the app, and no setup is necessary on a new telephone.
@MainActor
final class CameraControl: ObservableObject {
    enum Direction: String { case up, down, left, right }

    @Published private(set) var ptzReady = false
    @Published private(set) var powerReady = false
    @Published private(set) var lastError: String?

    private var ptzID: String? { didSet { ptzReady = ptzID != nil } }
    private var powerID: String? { didSet { powerReady = powerID != nil } }
    private let settings: Settings
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    init(settings: Settings) {
        self.settings = settings
        ptzID = UserDefaults.standard.string(forKey: "ptzID")
        powerID = UserDefaults.standard.string(forKey: "powerID")
        ptzReady = ptzID != nil          // The observers do not run in init.
        powerReady = powerID != nil
    }

    /// It reads `window.NURSERY_CONFIG = { ptzWebhook: '…', powerWebhook: '…' }`.
    func loadConfig() async {
        guard let url = URL(string: "http://\(settings.trimmedHost):1984/nursery/config.js") else { return }
        do {
            let (data, _) = try await session.data(from: url)
            let text = String(decoding: data, as: UTF8.self)
            ptzID = Self.value(of: "ptzWebhook", in: text)
            powerID = Self.value(of: "powerWebhook", in: text)
            UserDefaults.standard.set(ptzID, forKey: "ptzID")
            UserDefaults.standard.set(powerID, forKey: "powerID")
            Log.shared.add("camera control ready: move \(ptzReady), power \(powerReady)")
        } catch {
            Log.shared.add("config not loaded: \(error.localizedDescription)")
        }
    }

    static func value(of key: String, in text: String) -> String? {
        let pattern = key + #"\s*:\s*['"]([A-Za-z0-9_-]+)['"]"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// One full-size frame from go2rtc, to save or to share.
    func snapshot() async -> UIImage? {
        if MonitorEngine.isDemo { return UIImage(named: "DemoFrame") }
        let src = settings.quality == .high ? "nursery" : "nursery_sd"
        guard let url = URL(string: "http://\(settings.trimmedHost):1984/api/frame.jpeg?src=\(src)") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8          // go2rtc waits for a keyframe.
        do {
            let (data, response) = try await session.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return UIImage(data: data)
        } catch {
            Log.shared.add("snapshot failed: \(error.localizedDescription)")
            return nil
        }
    }

    func move(_ direction: Direction) async -> Bool {
        guard let ptzID else { return false }
        return await post(ptzID, body: "direction=\(direction.rawValue)")
    }

    func power(on: Bool) async -> Bool {
        guard let powerID else { return false }
        return await post(powerID, body: "state=\(on ? "on" : "off")")
    }

    private func post(_ id: String, body: String) async -> Bool {
        guard let url = URL(string: "http://\(settings.trimmedHost):8123/api/webhook/\(id)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        do {
            let (_, response) = try await session.data(for: req)
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            lastError = ok ? nil : "Home Assistant refused the command."
            return ok
        } catch {
            lastError = "Home Assistant does not answer."
            Log.shared.add("webhook failed: \(error.localizedDescription)")
            return false
        }
    }
}
