@preconcurrency import AVFoundation
import Combine
import UIKit

/// The iPhone at the baby: it sends its camera and its microphone to the parents' phones.
/// It runs the server and the capture, and gives the screen what it shows.
@MainActor
final class BabyUnit: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var parents = 0
    @Published private(set) var history: [Float] = Array(repeating: 0, count: 60)
    @Published private(set) var error: String?
    /// The phone is locked or in the background: iOS stopped the camera. The sound continues.
    @Published private(set) var cameraPaused = false

    let settings: Settings
    private var server: BabyServer?
    private var capture: BabyCapture?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(settings: Settings) {
        self.settings = settings
    }

    // MARK: Start and stop

    func start() async {
        guard !running else { return }
        error = nil
        if MonitorEngine.isDemo { startDemo(); return }

        guard await AVAudioApplication.requestRecordPermission() else {
            error = "Chůvička nemá přístup k mikrofonu. Povolte ho v Nastavení iPhonu → Chůvička."
            return
        }
        let video = settings.unitVideo
        if video, !(await AVCaptureDevice.requestAccess(for: .video)) {
            error = "Chůvička nemá přístup ke kameře. Povolte ho v Nastavení iPhonu → Chůvička, nebo zvolte Jen zvuk."
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            Log.shared.add("baby audio session: \(error.localizedDescription)")
        }

        let server = BabyServer(code: settings.unitCode, video: video)
        let capture = BabyCapture(server: server)
        server.onClients = { [weak self, weak capture] all, video in
            MainActor.assumeIsolated {
                self?.parents = all
                capture?.setEncoding(video > 0)
            }
        }
        server.onNeedKeyframe = { [weak capture] in capture?.requestKeyframe() }
        server.onFailure = { [weak self] message in
            MainActor.assumeIsolated {
                self?.stop()
                self?.error = message
            }
        }
        server.onFrameRequest = { [weak capture] done in
            guard let capture else { done(nil); return }
            capture.requestFrame(done)
        }
        do {
            try capture.startAudio()
            if video { try capture.startVideo(front: settings.unitFront, flipped: settings.unitFlip) }
            try server.start(name: Self.serviceName(settings.unitName), peerToPeer: settings.unitDirect)
        } catch {
            capture.stop()
            server.stop()
            self.error = error.localizedDescription
            Log.shared.add("baby unit failed: \(error.localizedDescription)")
            return
        }
        self.server = server
        self.capture = capture
        running = true
        // The camera needs the app on the screen. Sound only works with the phone locked too.
        UIApplication.shared.isIdleTimerDisabled = video
        startTimer()
        observe()
        Log.shared.add("baby unit on, \(video ? "picture and sound" : "sound only")")
    }

    func stop() {
        guard running else { return }
        timer?.invalidate(); timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        capture?.stop(); capture = nil
        server?.stop(); server = nil
        running = false
        parents = 0
        cameraPaused = false
        history = Array(repeating: 0, count: 60)
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        Log.shared.add("baby unit off")
    }

    /// The camera picture now, for the preview while the parent aims the phone.
    func previewFrame() async -> UIImage? {
        if MonitorEngine.isDemo { return UIImage(named: "DemoFrame") }
        guard let capture, settings.unitVideo else { return nil }
        let data: Data? = await withCheckedContinuation { cont in
            capture.requestFrame { cont.resume(returning: $0) }
        }
        return data.flatMap { UIImage(data: $0) }
    }

    // MARK: The level, 10 times a second

    private var smoothed: Float = 0

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let raw: Float
        if MonitorEngine.isDemo {
            let t = Date().timeIntervalSince1970
            raw = Float.random(in: 0.08...0.16) + (Int(t) % 12 < 2 ? 0.6 : 0)
        } else {
            raw = capture?.peak.withLock { v -> Float in let p = v; v = 0; return p } ?? 0
        }
        smoothed = raw > smoothed ? raw : smoothed * 0.82 + raw * 0.18
        // Only while the screen shows it. In the background each change still made SwiftUI
        // redraw, which got the parent app killed for its CPU use.
        guard UIApplication.shared.applicationState == .active else { return }
        var h = history
        h.removeFirst()
        h.append(smoothed)
        history = h
    }

    // MARK: Interruptions

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            MainActor.assumeIsolated {
                Log.shared.add("baby microphone: interruption ended")
                try? AVAudioSession.sharedInstance().setActive(true)
                self?.capture?.restartAudio()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Log.shared.add("baby: media services reset, start again")
                self.stop()
                Task { await self.start() }
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.shared.add("baby camera paused")
                self?.cameraPaused = true
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.shared.add("baby camera back")
                self?.cameraPaused = false
                self?.capture?.requestKeyframe()
            }
        })
    }

    /// A Bonjour name is at most 63 bytes of UTF-8. A Czech letter with a diacritic takes 2.
    static func serviceName(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        if s.isEmpty { s = "Pokojíček" }
        while s.utf8.count > 63 { s.removeLast() }
        return s
    }

    // MARK: Demo, for the screenshots

    private func startDemo() {
        running = true
        parents = 1
        startTimer()
    }
}
