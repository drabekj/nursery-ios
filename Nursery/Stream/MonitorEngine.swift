import AVFoundation
import Combine
import Network
import os
import UIKit

/// The monitor. It holds one RTSP session to go2rtc, and it feeds the picture and the sound.
///
/// The rules:
/// - The sound has priority. It continues in the background and on the lock screen.
/// - In the background with no picture in picture, the app asks go2rtc for the sound only.
///   The video of 2 Mbit/s then stops, and the battery lasts the night.
/// - A lost connection opens again by itself: after 1, 2, 4, then each 8 seconds.
@MainActor
final class MonitorEngine: ObservableObject {
    enum Connection: Equatable { case idle, connecting, live, retrying(String) }
    typealias SoundStatus = NurseryActivityAttributes.Status

    @Published private(set) var connection: Connection = .idle
    @Published private(set) var pictureLive = false
    @Published private(set) var soundStatus: SoundStatus = .connecting
    /// The loudness of the room now, 0...1.
    @Published private(set) var level: Float = 0
    /// The loudness in the last 6 seconds, oldest first. One value each 0.1 s.
    @Published private(set) var history: [Float] = Array(repeating: 0, count: 60)
    @Published private(set) var videoSize = CGSize(width: 16, height: 9)
    @Published private(set) var audioOnly = false
    @Published private(set) var delayMilliseconds = 0
    @Published var listening: Bool {
        didSet {
            UserDefaults.standard.set(listening, forKey: "listening")
            applyListening()
        }
    }

    let settings: Settings
    let videoView: VideoLayerView
    let pip = PictureInPicture()

    private struct Shared {
        var lastAudio = Date.distantPast
        var lastVideo = Date.distantPast
        var lastPacket = Date.distantPast
        var peak: Float = 0
        var renderVideo = true
    }
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let audio = LiveAudioPlayer()
    private let renderer: VideoRenderer
    private let nowPlaying = NowPlaying()
    private let activity = LiveActivityController()

    private var client: RTSPClient?
    private var generation = 0
    private var retryDelay: Double = 1
    private var retryTask: Task<Void, Never>?
    private var audioOnlyTask: Task<Void, Never>?
    private var isForeground = true
    private var everHeard = false
    private var lostSince: Date?
    private var alerted = false
    private var ticks = 0
    private var timer: Timer?
    private let pathMonitor = NWPathMonitor()
    private var bag = Set<AnyCancellable>()

    init(settings: Settings) {
        self.settings = settings
        listening = UserDefaults.standard.object(forKey: "listening") as? Bool ?? true
        let view = VideoLayerView()
        videoView = view
        renderer = VideoRenderer(layer: view.displayLayer)
        renderer.onSize = { [weak self] size in self?.videoSize = size }

        audio.onLevel = Self.levelSink(shared)
        audio.setGain(decibels: settings.loudness.decibels)

        pip.attach(to: videoView.displayLayer)
        pip.onActiveChange = { [weak self] active in self?.pictureInPictureChanged(active) }

        nowPlaying.onPlay = { [weak self] in self?.listening = true }
        nowPlaying.onPause = { [weak self] in self?.listening = false }

        settings.$loudness.dropFirst().sink { [weak self] l in self?.audio.setGain(decibels: l.decibels) }.store(in: &bag)
        settings.$quality.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reconnect(why: "quality changed") }
        }.store(in: &bag)

        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.audioInterrupted(note) }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.shared.add("media services reset")
                self?.audio.stop()
                self?.applyListening()
            }
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            DispatchQueue.main.async {
                // timer != nil: start() ran. The first path update comes before it.
                guard let self, self.timer != nil, self.connection != .live, self.connection != .connecting else { return }
                Log.shared.add("network is back")
                self.reconnect(why: "network is back")
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "nursery.path"))
    }

    // MARK: The life cycle

    func start() {
        activateAudioSession()
        nowPlaying.configure()
        applyListening()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
        if listening, settings.alertOnLoss { LossAlert.requestPermission() }
        connect()
    }

    func reconnect(why: String) {
        Log.shared.add("reconnect: \(why)")
        retryDelay = 1
        connect()
    }

    func sceneBecameActive() {
        isForeground = true
        audioOnlyTask?.cancel()
        UIApplication.shared.isIdleTimerDisabled = settings.keepAwake
        shared.withLock { $0.renderVideo = true }
        client?.queue.async { [renderer] in renderer.reset() }
        if audioOnly || client == nil { reconnect(why: "back in the foreground") }
    }

    func sceneEnteredBackground() {
        isForeground = false
        UIApplication.shared.isIdleTimerDisabled = false
        // Wait a moment. The small window can open during the move to the background.
        audioOnlyTask?.cancel()
        audioOnlyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.enterBackgroundMode()
        }
    }

    private func enterBackgroundMode() {
        guard !isForeground, !pip.isActive else { return }
        shared.withLock { $0.renderVideo = false }
        if listening {
            if !audioOnly { reconnect(why: "background: sound only") }
        } else {
            // No sound and no picture: nothing to do. Close the stream.
            Log.shared.add("background with no sound: stream closed")
            stopClient()
            connection = .idle
        }
    }

    private func pictureInPictureChanged(_ active: Bool) {
        Log.shared.add(active ? "picture in picture on" : "picture in picture off")
        if active {
            shared.withLock { $0.renderVideo = true }
            if audioOnly { reconnect(why: "picture in picture needs the video") }
        } else if !isForeground {
            enterBackgroundMode()
        }
    }

    // MARK: The connection

    private var wantsAudioOnly: Bool { !isForeground && !pip.isActive && listening }

    private func stopClient() {
        retryTask?.cancel()
        generation += 1          // An onClose from the old client is now stale. It does not reconnect.
        client?.stop()
        client = nil
    }

    private func connect() {
        stopClient()
        generation += 1
        let gen = generation
        let onlyAudio = wantsAudioOnly
        audioOnly = onlyAudio
        if connection != .live { connection = .connecting }
        let url = settings.streamURL(audioOnly: onlyAudio)

        let client: RTSPClient
        do { client = try RTSPClient(url: url) } catch {
            connection = .retrying("The server address is not valid.")
            return
        }
        self.client = client
        Log.shared.add("connect \(url)")

        client.onClose = Self.closeSink(engine: self, generation: gen)
        let prepare = Self.router(client: client, renderer: renderer, audio: audio, shared: shared)

        Task { [weak self] in
            do {
                let tracks = try await client.start(prepare: prepare)
                self?.connected(gen, tracks)
            } catch {
                self?.connectionEnded(gen, error)
            }
        }
    }

    // These closures run on the RTSP queue. They are nonisolated, so they never touch the main actor.

    nonisolated private static func levelSink(_ shared: OSAllocatedUnfairLock<Shared>) -> (Float) -> Void {
        { level in shared.withLock { $0.peak = max($0.peak, level) } }
    }

    nonisolated private static func closeSink(engine: MonitorEngine, generation: Int) -> (Error?) -> Void {
        { [weak engine] error in
            Task { @MainActor in engine?.connectionEnded(generation, error) }
        }
    }

    /// It sends each RTP packet to the video or the audio path. It runs before PLAY.
    nonisolated private static func router(client: RTSPClient, renderer: VideoRenderer, audio: LiveAudioPlayer,
                                           shared: OSAllocatedUnfairLock<Shared>) -> ([RTSPClient.Track]) -> Void {
        { [weak client] tracks in
            let depacketizer = H264Depacketizer()
            let video = tracks.first { $0.sdp.kind == .video }
            let sound = tracks.first { $0.sdp.kind == .audio }
            if let sets = video?.sdp.h264ParameterSets {
                depacketizer.setParameterSets(sps: sets.sps, pps: sets.pps)
            }
            let uLaw = sound?.sdp.codec == "PCMU"
            renderer.reset()
            client?.onPacket = { channel, bytes in
                guard let packet = RTPPacket(bytes) else { return }
                let now = Date()
                if channel == video?.channel {
                    guard let unit = depacketizer.push(packet) else { return }
                    let draw = shared.withLock { s -> Bool in
                        s.lastVideo = now
                        s.lastPacket = now
                        return s.renderVideo
                    }
                    if draw { renderer.render(unit, depacketizer: depacketizer) }
                } else if channel == sound?.channel {
                    shared.withLock { s in
                        s.lastAudio = now
                        s.lastPacket = now
                    }
                    audio.enqueue(payload: packet.payload, uLaw: uLaw)
                }
            }
        }
    }

    private func connected(_ gen: Int, _ tracks: [RTSPClient.Track]) {
        guard gen == generation else { return }
        let names = tracks.map { "\($0.sdp.kind.rawValue) \($0.sdp.codec)" }.joined(separator: ", ")
        Log.shared.add("playing: \(names)")
        connection = .live
        retryDelay = 1
    }

    private func connectionEnded(_ gen: Int, _ error: Error?) {
        guard gen == generation else { return }
        client = nil
        let message = (error as? LocalizedError)?.errorDescription ?? error?.localizedDescription ?? "The connection closed."
        Log.shared.add("connection ended: \(message)")
        connection = .retrying(message)
        pictureLive = false
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 8)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.connect()
        }
    }

    // MARK: The sound

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .playback: the sound continues on the lock screen and with the silent switch on.
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            Log.shared.add("audio session: \(error.localizedDescription)")
        }
    }

    private func applyListening() {
        if listening {
            activateAudioSession()
            audio.start()
            alerted = false
        } else {
            audio.stop()
            LossAlert.clear()
        }
        updateStatus(force: true)
        if !isForeground { enterBackgroundMode() }
    }

    private func audioInterrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            Log.shared.add("sound interrupted (for example a call)")
        case .ended:
            Log.shared.add("sound interruption ended")
            if listening {
                audio.stop()
                activateAudioSession()
                audio.start()
            }
        @unknown default:
            break
        }
    }

    // MARK: The clock (10 Hz)

    private func tick() {
        ticks += 1
        let now = Date()
        let s = shared.withLock { state -> Shared in
            let copy = state
            state.peak = 0
            return copy
        }

        // Fast attack, slow release. This is how a VU meter moves.
        let target = listening ? s.peak : 0
        let smoothed = target > level ? target : level * 0.82 + target * 0.18
        if isForeground || pip.isActive {
            level = smoothed
            history.removeFirst()
            history.append(smoothed)
        } else {
            level = smoothed        // The Live Activity still needs it.
        }

        guard ticks % 5 == 0 else { return }       // The rest runs at 2 Hz.
        pictureLive = now.timeIntervalSince(s.lastVideo) < 3
        delayMilliseconds = Int(audio.bufferedSeconds * 1000)
        if now.timeIntervalSince(s.lastAudio) < 3 { everHeard = true }

        // A half-open TCP connection gives no error. Detect it by the silence of the data.
        if connection == .live, now.timeIntervalSince(s.lastPacket) > 6 {
            reconnect(why: "no data for 6 s")
        }
        updateStatus(force: false, lastAudio: s.lastAudio)
        if ticks % 100 == 0 { activity.heartbeat() }
    }

    private func updateStatus(force: Bool, lastAudio: Date? = nil) {
        let heardRecently = Date().timeIntervalSince(lastAudio ?? shared.withLock { $0.lastAudio }) < 3
        let status: SoundStatus
        if !listening { status = .muted }
        else if heardRecently { status = .listening }
        else if !everHeard { status = .connecting }
        else { status = .lost }

        if status != soundStatus || force {
            if status != soundStatus { Log.shared.add("sound: \(status.title)") }
            soundStatus = status
            nowPlaying.update(status: status)
        }

        // The alert. Only a loss that lasts 20 s gives a notification.
        if status == .lost {
            if lostSince == nil { lostSince = Date() }
            if !alerted, settings.alertOnLoss, let since = lostSince, Date().timeIntervalSince(since) > 20 {
                alerted = true
                LossAlert.post()
            }
        } else {
            lostSince = nil
            if alerted, status == .listening { alerted = false; LossAlert.clear() }
        }

        let bucket = min(4, Int(level * 5))
        activity.update(status: status, level: status == .listening ? bucket : 0,
                        enabled: settings.liveActivity && listening)
    }
}
