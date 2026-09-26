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

/// The settings. The initial values of the server and the streams come from `HomeDefaults`.
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

    /// The first-run guide is done. An install from before the guide counts as done.
    @Published var onboarded: Bool { didSet { d.set(onboarded, forKey: "onboarded") } }
    @Published var cameraKind: CameraKind { didSet { d.set(cameraKind.rawValue, forKey: "cameraKind") } }
    @Published var rtspBrand: CameraBrand { didSet { d.set(rtspBrand.rawValue, forKey: "rtspBrand") } }
    @Published var rtspHost: String { didSet { d.set(rtspHost, forKey: "rtspHost") } }
    @Published var rtspPort: Int { didSet { d.set(rtspPort, forKey: "rtspPort") } }
    @Published var rtspUser: String { didSet { d.set(rtspUser, forKey: "rtspUser") } }
    /// "Jiná kamera": the address from the camera's manual, with no user and password.
    @Published var rtspCustom: String { didSet { d.set(rtspCustom, forKey: "rtspCustom") } }
    /// The go2rtc stream names: the camera's main (high) stream and its sub (low) stream.
    @Published var streamMain: String { didSet { d.set(streamMain, forKey: "streamMain") } }
    @Published var streamSmall: String { didSet { d.set(streamSmall, forKey: "streamSmall") } }
    @Published var host: String { didSet { d.set(host, forKey: "host") } }
    /// The server's Tailscale address. Away from home the app uses it when the LAN address does not answer.
    @Published var remoteHost: String { didSet { d.set(remoteHost, forKey: "remoteHost") } }
    /// The address that the app uses now: `host` at home, `remoteHost` away. The engine sets it.
    @Published var activeHost: String = ""
    /// The addresses that the phone at the baby reported ("100.101.102.103:8555" first).
    /// Away from home Bonjour does not work, so the parent uses them.
    @Published var babyAddresses: [String] { didSet { d.set(babyAddresses, forKey: "babyAddresses") } }
    /// The address of the phone at the baby now, when the app does not use Bonjour. The engine sets it.
    @Published var babyDirect: String?
    @Published var loudness: Loudness { didSet { d.set(loudness.rawValue, forKey: "loudness") } }
    @Published var keepAwake: Bool { didSet { d.set(keepAwake, forKey: "keepAwake") } }
    @Published var alertOnSound: Bool { didSet { d.set(alertOnSound, forKey: "alertOnSound") } }
    @Published var sensitivity: Sensitivity { didSet { d.set(sensitivity.rawValue, forKey: "sensitivity") } }
    @Published var appearance: Appearance { didSet { d.set(appearance.rawValue, forKey: "appearance") } }
    @Published var role: Role { didSet { d.set(role.rawValue, forKey: "role") } }
    @Published var source: Source { didSet { d.set(source.rawValue, forKey: "source") } }
    /// Pan, tilt and power through Home Assistant. Off in a public build (no `HomeDefaults.configPath`).
    @Published var cameraControl: Bool { didSet { d.set(cameraControl, forKey: "cameraControl") } }
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
        // An install from before the guide has settings already: it needs no guide.
        let defaults = UserDefaults.standard       // Not `d`: a closure may not capture self yet.
        let existing = ["host", "soundMode", "soundView", "source", "loudness", "alertOfferShown", "nightExplained", "role"]
            .contains { defaults.object(forKey: $0) != nil }
        onboarded = d.object(forKey: "onboarded") as? Bool ?? existing
        cameraKind = CameraKind(rawValue: d.string(forKey: "cameraKind") ?? "") ?? .go2rtc
        rtspBrand = CameraBrand(rawValue: d.string(forKey: "rtspBrand") ?? "") ?? .tapo
        rtspHost = d.string(forKey: "rtspHost") ?? ""
        rtspPort = d.object(forKey: "rtspPort") as? Int ?? 554
        rtspUser = d.string(forKey: "rtspUser") ?? ""
        rtspCustom = d.string(forKey: "rtspCustom") ?? ""
        streamMain = d.string(forKey: "streamMain") ?? HomeDefaults.streamMain
        streamSmall = d.string(forKey: "streamSmall") ?? HomeDefaults.streamSmall
        host = d.string(forKey: "host") ?? HomeDefaults.serverHost
        remoteHost = d.string(forKey: "remoteHost") ?? HomeDefaults.remoteHost
        babyAddresses = d.stringArray(forKey: "babyAddresses") ?? []
        loudness = Loudness(rawValue: d.string(forKey: "loudness") ?? "") ?? .normal
        keepAwake = d.object(forKey: "keepAwake") as? Bool ?? true
        alertOnSound = d.object(forKey: "alertOnSound") as? Bool ?? false
        sensitivity = Sensitivity(rawValue: d.string(forKey: "sensitivity") ?? "") ?? .medium
        appearance = Appearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .automatic
        role = Role(rawValue: d.string(forKey: "role") ?? "") ?? .parent
        source = Source(rawValue: d.string(forKey: "source") ?? "") ?? .camera
        cameraControl = d.object(forKey: "cameraControl") as? Bool ?? !HomeDefaults.configPath.isEmpty
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
            onboarded = !screen.hasPrefix("wizard")
            role = screen.hasPrefix("baby") ? .baby : .parent
            unitCode = "482913"
        }
        // The screenshots of the sound view use `-demoScreen sound…`.
        soundView = MonitorEngine.isDemo ? d.string(forKey: "demoScreen")?.hasPrefix("sound") == true : d.bool(forKey: "soundView")
        // The code stays the same after a restart, so the parents stay paired.
        if !MonitorEngine.isDemo, d.string(forKey: "unitCode") == nil { d.set(unitCode, forKey: "unitCode") }
        // The picture quality is automatic now (StreamPolicy). The old setting is not used.
        d.removeObject(forKey: "quality")
    }

    var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedRemoteHost: String { remoteHost.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The Pi now: at home its LAN address, away its Tailscale address.
    var serverHost: String { activeHost.isEmpty ? trimmedHost : activeHost }

    static func newCode() -> String { String(format: "%06d", Int.random(in: 0...999_999)) }

    /// The iPhone at the baby, as a Bonjour service. Nil when the source is the camera.
    var babyEndpoint: NWEndpoint? {
        guard source == .phone, !babyName.isEmpty else { return nil }
        if let babyDirect, let a = Reach.split(babyDirect), let port = NWEndpoint.Port(rawValue: a.port) {
            return .hostPort(host: NWEndpoint.Host(a.host), port: port)
        }
        return BabyLink.endpoint(name: babyName)
    }

    /// The detail (main) and the everyday (sub) stream of the source, for `StreamPolicy`.
    /// The same value when the source has one stream only.
    var streamNames: (detail: String, everyday: String) {
        switch source {
        case .phone: return ("", "")
        case .camera where cameraKind == .rtsp:
            let p = rtspBrand.paths
            return (p.main, p.small ?? p.main)
        case .camera: return (streamMain, streamSmall)
        }
    }

    /// The RTSP stream: the go2rtc restream, or the iPhone at the baby. The query "?audio" asks the phone for the sound only.
    /// `small`: the everyday (sub) stream, as `StreamPolicy` decided. Sound only is always the sub stream.
    func streamURL(audioOnly: Bool, small: Bool) -> String {
        if source == .phone {
            // The host is not used: the connection goes to the Bonjour service. The code is the path.
            return "rtsp://chuvicka/\(babyCode)" + (audioOnly ? "?audio" : "")
        }
        // Sound only from a camera: the sub stream, with its picture, and the app does not draw it.
        // Not "?audio": some cameras (e.g. Tapo through go2rtc) send no packets on an audio-only
        // request, because go2rtc then sets up only the sound track with the camera. With Tapo it
        // worked only while another phone watched the same stream, so the sound view, Night mode
        // and the background failed at random. Tested on 25 Sep 2026 with Tools/rtsp_check.py.
        // The Tapo sub stream (360p) costs about 0.3 Mbit/s.
        let sub = audioOnly || small
        if cameraKind == .rtsp { return rtspURL(small: sub) }
        return "rtsp://\(serverHost):\(Go2rtc.rtspPort)/\(sub ? streamSmall : streamMain)"
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
        ptzID = settings.cameraControl ? UserDefaults.standard.string(forKey: "ptzID") : nil
        powerID = settings.cameraControl ? UserDefaults.standard.string(forKey: "powerID") : nil
        ptzReady = ptzID != nil          // The observers do not run in init.
        powerReady = powerID != nil
    }

    /// It reads `window.NURSERY_CONFIG = { ptzWebhook: '…', powerWebhook: '…' }`.
    func loadConfig() async {
        // Camera control is off in the settings: no aim, no power button.
        guard settings.cameraControl else {
            if ptzID != nil || powerID != nil { Log.shared.add("camera control off") }
            ptzID = nil
            powerID = nil
            UserDefaults.standard.removeObject(forKey: "ptzID")
            UserDefaults.standard.removeObject(forKey: "powerID")
            return
        }
        // Only with go2rtc: a camera read directly has no config file, so there is nothing to ask.
        guard !HomeDefaults.configPath.isEmpty, settings.cameraKind == .go2rtc else { return }
        guard let url = URL(string: "http://\(settings.serverHost):\(Go2rtc.apiPort)/\(HomeDefaults.configPath)") else { return }
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
            guard let endpoint = settings.babyEndpoint else { return nil }
            return await BabyLink.frame(endpoint: endpoint, code: settings.babyCode)
        }
        // A camera with no go2rtc gives no photo on request.
        guard settings.cameraKind == .go2rtc else { return nil }
        let src = settings.streamMain          // Always the main stream: a photo should be sharp.
        guard let url = URL(string: "http://\(settings.serverHost):\(Go2rtc.apiPort)/api/frame.jpeg?src=\(src)") else { return nil }
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
        guard let url = URL(string: "http://\(settings.serverHost):\(HomeAssistant.port)/api/webhook/\(id)") else { return false }
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
