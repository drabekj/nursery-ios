import Combine
import Foundation
import Network
import os
import UIKit

/// The events, for the diagnosis screen. The telephone gives no console, so this list is the
/// only way to see why the sound stopped at 3 a.m. It is saved to a file, so it survives a crash
/// or a stop by iOS: a gap in the times shows when the app did not run.
final class Log: ObservableObject, @unchecked Sendable {
    static let shared = Log()
    struct Entry: Identifiable { let id = UUID(); let time: Date; let text: String }

    @Published private(set) var entries: [Entry] = []
    private let logger = Logger(subsystem: "cz.drabek.nursery", category: "monitor")
    private let fileQueue = DispatchQueue(label: "nursery.log")
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("events.log")
    }()
    private static let keep = 400

    init() {
        // Load the last events of earlier runs, and keep the file short.
        let lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .split(separator: "\n").suffix(Self.keep).map(String.init)
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: url, atomically: true, encoding: .utf8)
        entries = lines.compactMap { line in
            guard let tab = line.firstIndex(of: "\t"),
                  let t = TimeInterval(line[..<tab]) else { return nil }
            return Entry(time: Date(timeIntervalSince1970: t), text: String(line[line.index(after: tab)...]))
        }
    }

    func add(_ text: String) {
        logger.info("\(text, privacy: .public)")
        let entry = Entry(time: Date(), text: text)
        let line = String(format: "%.0f\t", entry.time.timeIntervalSince1970) + text.replacingOccurrences(of: "\n", with: " ") + "\n"
        fileQueue.async {
            if let handle = try? FileHandle(forWritingTo: self.url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: self.url, atomically: true, encoding: .utf8)
            }
        }
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > Self.keep { self.entries.removeFirst(self.entries.count - Self.keep) }
        }
    }

    var text: String {
        let f = DateFormatter()
        f.dateFormat = "dd.MM. HH:mm:ss"
        return entries.map { "\(f.string(from: $0.time))  \($0.text)" }.joined(separator: "\n")
    }
}

/// The settings. The defaults work on the home Wi-Fi with no setup.
final class Settings: ObservableObject {
    enum Loudness: String, CaseIterable, Identifiable {
        case normal, loud, max
        var id: String { rawValue }
        var title: String { switch self { case .normal: "Normální"; case .loud: "Zesílená"; case .max: "Maximální" } }
        var decibels: Float { switch self { case .normal: 0; case .loud: 12; case .max: 20 } }
    }

    /// The level at which a sound counts as an event, for the activity and the alerts.
    enum Sensitivity: String, CaseIterable, Identifiable {
        case low, medium, high
        var id: String { rawValue }
        var title: String { switch self { case .low: "Jen hlasitý pláč"; case .medium: "Pláč i fňukání"; case .high: "Každý zvuk" } }
        /// How far above the noise floor of the room a sound must be.
        var margin: Float { switch self { case .low: 0.32; case .medium: 0.2; case .high: 0.12 } }
    }

    enum Quality: String, CaseIterable, Identifiable {
        case high, low
        var id: String { rawValue }
        var title: String { switch self { case .high: "2K (ostré přiblížení)"; case .low: "360p (úspora baterie)" } }
    }

    /// What this iPhone does: it watches (the parent) or it is the camera at the baby.
    enum Role: String { case parent, baby }

    /// Where the parent gets the picture and the sound.
    enum Source: String, CaseIterable, Identifiable {
        case camera, phone
        var id: String { rawValue }
        var title: String { switch self { case .camera: "Kamera v pokojíčku"; case .phone: "Telefon u miminka" } }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case light, dark, automatic
        var id: String { rawValue }
        var title: String { switch self { case .light: "Světlý"; case .dark: "Tmavý"; case .automatic: "Automaticky" } }
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
    @Published var role: Role { didSet { d.set(role.rawValue, forKey: "role") } }
    @Published var source: Source { didSet { d.set(source.rawValue, forKey: "source") } }
    /// On the parent: the Bonjour name of the iPhone at the baby, and its pairing code.
    @Published var babyName: String { didSet { d.set(babyName, forKey: "babyName") } }
    @Published var babyCode: String { didSet { d.set(babyCode, forKey: "babyCode") } }
    /// On the iPhone at the baby: its name for the parents, its code, and its camera.
    @Published var unitName: String { didSet { d.set(unitName, forKey: "unitName") } }
    @Published var unitCode: String { didSet { d.set(unitCode, forKey: "unitCode") } }
    @Published var unitVideo: Bool { didSet { d.set(unitVideo, forKey: "unitVideo") } }
    @Published var unitFront: Bool { didSet { d.set(unitFront, forKey: "unitFront") } }
    @Published var unitFlip: Bool { didSet { d.set(unitFlip, forKey: "unitFlip") } }
    /// Also offer the stream over peer-to-peer Wi-Fi, for a place with no Wi-Fi router.
    @Published var unitDirect: Bool { didSet { d.set(unitDirect, forKey: "unitDirect") } }
    /// The main screen shows the room only, with no picture. See `MonitorEngine.setSoundView`.
    @Published var soundView: Bool { didSet { if !MonitorEngine.isDemo { d.set(soundView, forKey: "soundView") } } }

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
        role = Role(rawValue: d.string(forKey: "role") ?? "") ?? .parent
        source = Source(rawValue: d.string(forKey: "source") ?? "") ?? .camera
        babyName = d.string(forKey: "babyName") ?? ""
        babyCode = d.string(forKey: "babyCode") ?? ""
        unitName = d.string(forKey: "unitName") ?? "Pokojíček"
        unitCode = d.string(forKey: "unitCode") ?? Settings.newCode()
        unitVideo = d.object(forKey: "unitVideo") as? Bool ?? true
        unitFront = d.bool(forKey: "unitFront")
        unitFlip = d.bool(forKey: "unitFlip")
        unitDirect = d.bool(forKey: "unitDirect")
        if MonitorEngine.isDemo {
            let screen = d.string(forKey: "demoScreen") ?? ""
            role = screen.hasPrefix("baby") ? .baby : .parent
            unitCode = "482913"
        }
        // The screenshots of the sound view use `-demoScreen sound…`.
        soundView = MonitorEngine.isDemo ? d.string(forKey: "demoScreen")?.hasPrefix("sound") == true : d.bool(forKey: "soundView")
        // The code stays the same after a restart, so the parents stay paired.
        if !MonitorEngine.isDemo, d.string(forKey: "unitCode") == nil { d.set(unitCode, forKey: "unitCode") }
    }

    var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func newCode() -> String { String(format: "%06d", Int.random(in: 0...999_999)) }

    /// The iPhone at the baby, as a Bonjour service. Nil when the source is the camera.
    var babyEndpoint: NWEndpoint? {
        source == .phone && !babyName.isEmpty ? BabyLink.endpoint(name: babyName) : nil
    }

    /// The RTSP stream: the go2rtc restream, or the iPhone at the baby. The query "?audio" asks go2rtc for the sound only.
    func streamURL(audioOnly: Bool) -> String {
        if source == .phone {
            // The host is not used: the connection goes to the Bonjour service. The code is the path.
            return "rtsp://chuvicka/\(babyCode)" + (audioOnly ? "?audio" : "")
        }
        // Sound only from the Tapo camera: the small 360p stream, with its picture, and the app
        // does not draw it. Not "?audio": go2rtc then sets up only the sound track with the camera,
        // and the Tapo camera sends no packets at all. It worked only while another phone watched
        // the same stream, so the sound view, Night mode and the background failed at random.
        // Tested on 25 Sep 2026 with Tools/rtsp_check.py. The 360p picture costs about 0.3 Mbit/s.
        if audioOnly { return "rtsp://\(trimmedHost):8554/nursery_sd" }
        let name = quality == .high ? "nursery" : "nursery_sd"
        return "rtsp://\(trimmedHost):8554/\(name)"
    }
}

/// The pan, the tilt, and the power, through the Home Assistant webhooks.
/// The webhook ids come from the config file that go2rtc already serves on the LAN.
/// Thus no id is in the app, and no setup is necessary on a new telephone.
@MainActor
final class CameraControl: ObservableObject {
    enum Direction: String {
        case up, down, left, right
        /// For VoiceOver: "Otočit kameru nahoru".
        var czech: String { switch self { case .up: "nahoru"; case .down: "dolů"; case .left: "doleva"; case .right: "doprava" } }
    }

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
    /// Aim needs the Tapo camera. The iPhone at the baby cannot turn.
    var canAim: Bool { ptzReady && settings.source == .camera }

    func snapshot() async -> UIImage? {
        if MonitorEngine.isDemo { return UIImage(named: "DemoFrame") }
        if settings.source == .phone {
            guard !settings.babyName.isEmpty else { return nil }
            return await BabyLink.frame(name: settings.babyName, code: settings.babyCode)
        }
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
            lastError = ok ? nil : "Home Assistant příkaz odmítl."
            return ok
        } catch {
            lastError = "Home Assistant neodpovídá."
            Log.shared.add("webhook failed: \(error.localizedDescription)")
            return false
        }
    }
}
