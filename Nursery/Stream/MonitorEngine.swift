import ActivityKit
import AVFoundation
import MediaPlayer
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

    /// Live: you hear the room. Silent: you hear nothing, and a sound gives a notification.
    /// Off: no sound. In the background, Live and Silent keep the app awake.
    enum SoundMode: String, CaseIterable, Identifiable {
        /// Muted is not off: the app plays nothing, but it still hears the room and warns about a cry.
        /// Only "Ukončit hlídání" stops the listening.
        case live, off
        var id: String { rawValue }
        var title: String { switch self { case .live: "Živý zvuk"; case .off: "Ztlumeno" } }
        var symbol: String { switch self { case .live: "speaker.wave.2.fill"; case .off: "speaker.slash.fill" } }
    }

    /// The one state that the screen shows. It joins the connection and the picture.
    enum Overall: Equatable { case live, soundOnly, connecting, reconnecting, offline(String) }

    /// The demo mode shows a still picture and a fake sound. Start the app with `-demo YES`.
    nonisolated static let isDemo = UserDefaults.standard.bool(forKey: "demo")

    @Published private(set) var connection: Connection = .idle
    @Published private(set) var pictureLive = false
    @Published private(set) var soundStatus: SoundStatus = .connecting
    /// The loudness for the meters. It changes 10 times a second, so it is a separate object:
    /// only the waveform, the orb and the glow redraw, not every view that watches the engine.
    let levels = LevelMeter()
    /// The smoothed level. It runs also in the background, where `levels` does not change.
    private var meter: Float = 0
    @Published private(set) var videoSize = CGSize(width: 16, height: 9)
    /// The loudness in words, with a hold time. A louder word shows after 0.4 s, a quieter one after 2.5 s.
    @Published private(set) var roomLevel: RoomLevel = .quiet
    /// What the room does, in one word: Připojuji, Klid, Ozývá se, Pláče, Nehlídá. It is computed
    /// at the 2 Hz tick and set only when the word changes.
    @Published private(set) var roomState: RoomState = .connecting
    /// When `roomState` last changed. The sublines count from it ("už 38 s", "před 2 min").
    @Published private(set) var roomStateSince = Date()
    /// The end of the last finished sound event, for "ticho už 42 min". Nil before the first one.
    var lastEventEnd: Date? { activityLog.events.last?.end }
    @Published private(set) var audioOnly = false
    @Published private(set) var delayMilliseconds = 0
    @Published private(set) var failures = 0
    /// A short message for a toast, for example after the camera was found at a new address.
    /// The screen shows it, then calls `clearNotice()`.
    @Published private(set) var notice: String?
    /// The iPhone's own volume, 0...1. The app cannot change it by code, but it can warn when it is low.
    @Published private(set) var systemVolume: Float = 1
    /// Live sound at a volume that a sleeping parent may not hear.
    var volumeLow: Bool { mode == .live && systemVolume < 0.2 }
    @Published var mode: SoundMode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: "soundMode")
            applyMode()
        }
    }

    var overall: Overall {
        switch connection {
        case .live: return audioOnly ? .soundOnly : .live
        case .idle, .connecting: return .connecting
        case .retrying(let why): return failures >= 2 ? .offline(why) : .reconnecting
        }
    }

    let settings: Settings
    let videoView: VideoLayerView
    let pip = PictureInPicture()
    let activityLog = SoundActivity()

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
    private var networkUp = true
    private var retryTask: Task<Void, Never>?
    private var audioOnlyTask: Task<Void, Never>?
    private var isForeground = true
    private var everHeard = false
    private var lostSince: Date?
    private var alerted = false
    private var louderSince: Date?
    private var quieterSince: Date?
    private var lastSoundAlert = Date.distantPast
    private var lastWatchdog = Date.distantPast
    private var lastAlive = Date()
    private var lastAliveCPU = MonitorEngine.processCPUSeconds()
    /// The rules behind `roomState`. Fed at 2 Hz, and with the verdicts of the cry classifier.
    private var roomMachine = RoomStateMachine()
    /// The cry classifier can run. False after it failed: then the loudness rule decides.
    private var classifierAvailable = true
    /// It hears a baby cry in the sound. It gets the samples only during a sound event.
    private lazy var cry = CryDetector(format: audio.format)
    private var cryListening = false

    /// The processor time of the whole app, in seconds.
    nonisolated private static func processCPUSeconds() -> Double {
        var t = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t)
        return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
    }
    private var ticks = 0
    private var timer: Timer?
    private let pathMonitor = NWPathMonitor()
    private var volumeObservation: NSKeyValueObservation?
    private var bag = Set<AnyCancellable>()

    init(settings: Settings) {
        self.settings = settings
        let saved = UserDefaults.standard.string(forKey: "soundMode") ?? ""
        var savedMode = SoundMode(rawValue: saved) ?? (saved == "silent" ? .off : .live)   // "silent" was the old muted mode.
        if Self.isDemo {
            let screen = UserDefaults.standard.string(forKey: "demoScreen")
            savedMode = screen == "muted" || screen == "sound-muted" ? .off : .live
        }
        mode = savedMode
        let view = VideoLayerView()
        videoView = view
        renderer = VideoRenderer(layer: view.displayLayer)
        renderer.onSize = { [weak self] size in self?.videoSize = size }

        audio.onLevel = Self.levelSink(shared)
        audio.setGain(decibels: settings.loudness.decibels)

        pip.attach(to: videoView.displayLayer)
        pip.automatic = !settings.soundView
        pip.onActiveChange = { [weak self] active in self?.pictureInPictureChanged(active) }

        nowPlaying.onPlay = { [weak self] in self?.soundOn() }
        nowPlaying.onPause = { [weak self] in self?.mode = .off }

        activityLog.margin = settings.sensitivity.margin
        activityLog.onEpisodeStart = { [weak self] episode in self?.episodeStarted(episode) }
        settings.$sensitivity.sink { [weak self] s in self?.activityLog.margin = s.margin }.store(in: &bag)
        if !Self.isDemo {           // The demo sets the words directly. No classifier there.
            cry.setSinks(verdict: Self.verdictSink(engine: self), failure: Self.cryFailureSink(engine: self))
            audio.onSamples = { [cry] samples in cry.feed(samples) }
        }

        settings.$loudness.dropFirst().sink { [weak self] l in self?.audio.setGain(decibels: l.decibels) }.store(in: &bag)
        // A new source, or a new pairing: connect again.
        Publishers.CombineLatest3(settings.$source, settings.$babyName, settings.$babyCode)
            .dropFirst()
            .removeDuplicates { $0 == $1 }
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reconnect(why: "source changed") } }
            .store(in: &bag)

        let center = NotificationCenter.default
        center.addObserver(forName: .stopMonitoring, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause(why: "lock screen button") }
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.audioInterrupted(note) }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.shared.add("media services reset")
                self?.audio.recreate()
                self?.applyMode()
            }
        }

        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                Log.shared.add("audio route change, reason \(raw)")
                self?.audio.heal()
            }
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self else { return }
                // Only a real return of the network. Tailscale, a Wi-Fi roam or a new route also
                // send a "satisfied" update, and each one cut the backoff and reconnected at once.
                let wasDown = !self.networkUp
                self.networkUp = satisfied
                // timer != nil: start() ran. The first path update comes before it.
                guard satisfied, wasDown, self.timer != nil, !self.suspended,
                      self.connection != .live, self.connection != .connecting else { return }
                Log.shared.add("network is back")
                self.reconnect(why: "network is back")
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "nursery.path"))

        // "Hey Siri, listen to the nursery" (see Intents.swift).
        center.addObserver(forName: .nurseryListen, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mode = .live }
        }
        center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.thermalChanged() }
        }
        thermalChanged()
        // Posted on a background queue. The .main queue brings it to the main thread.
        center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lowPowerChanged() }
        }
        lowPowerChanged()
    }

    func soundOn() { mode = .live }

    func clearNotice() { notice = nil }

    // MARK: The life cycle

    /// This iPhone is at the baby now. The parent's monitor sleeps: no stream, no sound, no alerts.
    private(set) var suspended = false
    var hasStarted: Bool { timer != nil }

    func suspend() {
        guard !suspended else { return }
        suspended = true
        Log.shared.add("monitor suspended: this iPhone is at the baby")
        stopClient()
        connection = .idle
        audio.stop()
        activityLog.interrupt()
        setCryListening(false)
        NurseryAlerts.disarmWatchdog()
        NurseryAlerts.clearLoss()
        activity.end()
        detailActive = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// The parent turned the monitor off: "Ukončit hlídání" in the app or on the lock screen.
    @Published private(set) var paused = false

    func pause(why: String) {
        guard !paused else { return }
        Log.shared.add("monitoring off: \(why)")
        paused = true
        suspend()
    }

    func unpause() {
        guard paused else { return }
        paused = false
        resume()
    }

    /// The user closed the app (swiped it away). Nothing may look as if it still watches:
    /// the Live Activity goes at once, and the "stopped watching" alarm is not needed, because
    /// the user stopped it. When iOS itself ends the app, this does not run, and the alarm fires.
    func appWillTerminate() {
        Log.shared.add("app closed by the user")
        NurseryAlerts.disarmWatchdog()
        NurseryAlerts.clearLoss()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for a in Activity<NurseryActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1.5)       // iOS gives the app a few seconds here.
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        Log.shared.add("monitor resumed")
        guard hasStarted else { start(); return }
        applyMode()
        reconnect(why: "monitor resumed")
    }

    func start() {
        Log.shared.add("app started, version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer?.tolerance = 0.03          // iOS may then join the wake-ups with other work.
        }
        if Self.isDemo { startDemo(); return }
        // A fresh start: a "stopped watching" alert that an earlier run left (iOS or Xcode ended
        // it in the background) is false now. Without this it fired 2.5 min after the new start,
        // because the first scene phase is .active and no change calls sceneBecameActive().
        NurseryAlerts.disarmWatchdog()
        activateAudioSession()
        nowPlaying.configure()
        applyMode()
        connect()
    }

    private func startDemo() {
        connection = .live
        everHeard = true
        if UserDefaults.standard.string(forKey: "demoScreen") == "volume" { systemVolume = 0.12 }
        audioOnly = settings.soundView
        activityLog.loadDemo()
        if let state = Self.demoRoomState {
            // A fixed word for the screenshot. The subline counts from a believable moment.
            roomState = state
            roomStateSince = Date().addingTimeInterval(state == .cry ? -38 : state == .lost ? -120 : 0)
        }
        if let image = UIImage(named: "DemoFrame") { renderer.showStill(image) }
        shared.withLock { $0.lastVideo = .distantFuture; $0.lastAudio = .distantFuture; $0.lastPacket = .distantFuture }
    }

    /// The fixed word of a demo screen (`-demoScreen klid`, `sound-cry`...). Nil: the word follows
    /// the fake level, as the other screens did before the words existed.
    private static let demoRoomState: RoomState? = {
        switch UserDefaults.standard.string(forKey: "demoScreen") {
        case "klid", "main": return .calm
        case "sound", "sound-muted": return .sound
        case "sound-cry", "main-cry", "night-cry": return .cry
        case "sound-lost": return .lost
        case "sound-connecting": return .connecting
        default: return nil
        }
    }()

    /// A fake room for the demo: a quiet hiss, and a short cry each 12 seconds.
    private func demoLevel() -> Float {
        let t = Date().timeIntervalSince1970
        let phase = t.truncatingRemainder(dividingBy: 12)
        let noise = Float.random(in: 0.06...0.16)
        guard phase > 8.5 else { return noise }
        let cry = Float(abs(sin(t * 5.5))) * 0.55 + 0.3
        return max(noise, cry)
    }

    func reconnect(why: String) {
        Log.shared.add("reconnect: \(why)")
        retryDelay = 1
        connect()
    }

    func sceneBecameActive() {
        guard !suspended else { return }
        isForeground = true
        Log.shared.add("foreground")
        NurseryAlerts.disarmWatchdog()
        NurseryAlerts.clearInterrupted()
        // Back from an interruption that never ended (or a tap on its notification): take the
        // sound back now. In the foreground iOS allows it, unless a call goes on.
        if !Self.isDemo, !audio.isRunning {
            endRecovery()
            activateAudioSession()
            audio.setInterrupted(false)
            audio.start()
            audio.setMuted(mode == .off)
        }
        audioOnlyTask?.cancel()
        UIApplication.shared.isIdleTimerDisabled = settings.keepAwake
        let render = wantsPicture
        shared.withLock { $0.renderVideo = render }
        client?.queue.async { [renderer] in renderer.reset() }
        updateStream(why: "back in the foreground")
    }

    func sceneEnteredBackground() {
        guard !suspended else { return }
        isForeground = false
        Log.shared.add("background, sound \(mode.rawValue)")
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
        // Also with the sound muted: the app still listens, to warn about a cry.
        updateStream(why: "background: sound only")
    }

    private func pictureInPictureChanged(_ active: Bool) {
        Log.shared.add(active ? "picture in picture on" : "picture in picture off")
        if active {
            shared.withLock { $0.renderVideo = true }
            client?.queue.async { [renderer] in renderer.reset() }
            updateStream(why: "picture in picture needs the video")
        } else if !isForeground {
            enterBackgroundMode()
        }
    }

    // MARK: The connection

    /// The picture is needed only on a screen that shows it: not in Night mode, not in the sound view.
    private var wantsPicture: Bool { !nightMode && !settings.soundView }

    /// In the foreground, the app asks for the sound only when no screen shows the picture.
    /// In the background, it asks for the sound only.
    private var wantsAudioOnly: Bool {
        guard !pip.isActive else { return false }
        return isForeground ? !wantsPicture : true
    }

    private func stopClient() {
        guard !Self.isDemo else { return }
        retryTask?.cancel()
        generation += 1          // An onClose from the old client is now stale. It does not reconnect.
        client?.stop()
        client = nil
    }

    private func connect() {
        guard !Self.isDemo, !suspended else { return }
        stopClient()
        if settings.source == .phone && (settings.babyName.isEmpty || settings.babyCode.isEmpty) {
            connection = .retrying("Není spárovaný telefon u miminka. Spárujte ho v Nastavení → Kamera.")
            failures = max(failures, 2)
            return
        }
        // Each attempt gets 6 s before the "no data" check can fire. Without this, the check fired
        // again every 0.5 s and killed each new attempt before it could finish.
        shared.withLock { $0.lastPacket = Date() }
        generation += 1
        let gen = generation
        let onlyAudio = wantsAudioOnly
        audioOnly = onlyAudio
        if connection != .live { connection = .connecting }

        Task { [weak self] in
            guard let self else { return }
            await self.chooseRoute()
            // A newer attempt started while this one looked for the way.
            guard gen == self.generation, !self.suspended else { return }
            let (url, detail) = self.stream(audioOnly: onlyAudio)
            self.currentURL = url
            if self.detailActive != detail { self.detailActive = detail }
            let client: RTSPClient
            let direct = self.settings.source == .camera && self.settings.cameraKind == .rtsp
            do { client = try RTSPClient(url: url, endpoint: self.settings.babyEndpoint, directCamera: direct) } catch {
                self.connection = .retrying("Adresa serveru není platná.")
                return
            }
            self.client = client
            // Not the URL: it carries the camera password or the pairing code, and the log is shared.
            let target = self.settings.source == .phone ? "the phone at the baby" : self.settings.cameraKind == .go2rtc ? "go2rtc \(self.settings.serverHost)" : "the camera \(self.settings.rtspHost)"
            Log.shared.add("connect \(target)\(onlyAudio ? " (sound only)" : detail ? " (main stream)" : "")\(self.viaTailscale ? " over Tailscale" : "")")
            client.onClose = Self.closeSink(engine: self, generation: gen)
            let prepare = Self.router(client: client, renderer: self.renderer, audio: self.audio, shared: self.shared)
            do {
                let tracks = try await client.start(prepare: prepare)
                self.connected(gen, tracks, reported: client.serverAddresses)
            } catch {
                self.connectionEnded(gen, error)
            }
        }
    }

    // MARK: The way: at home directly, away from home over Tailscale

    /// True when the stream goes over Tailscale (the phone is away from home).
    @Published private(set) var viaTailscale = false

    private func chooseRoute() async {
        switch settings.source {
        case .camera where settings.cameraKind == .rtsp:
            // The camera has one address, its LAN address. Away from home, the home's Tailscale
            // subnet route carries it. Only for the "Cesta" row: the connection is the same.
            let away = Self.cameraOverTailscale(host: settings.rtspHost, local: Reach.localAddresses())
            if viaTailscale != away { viaTailscale = away }
        case .camera:
            // The LAN address first: at home it answers at once. Away, it does not, in 1.2 s.
            let home = settings.trimmedHost
            let remote = settings.trimmedRemoteHost
            var host = home
            if !remote.isEmpty, remote != home, !(await Reach.canConnect(host: home, port: Go2rtc.rtspPort)) { host = remote }
            // Set only a change: each set redraws every view that watches the settings.
            if settings.activeHost != host {
                Log.shared.add("server: \(host == home ? "home" : "Tailscale") \(host)")
                settings.activeHost = host
            }
            if viaTailscale != (host != home) { viaTailscale = host != home }
        case .phone:
            // The addresses that the phone reported last time first: the home Wi-Fi, then Tailscale.
            // They need no Bonjour. An Android phone with the screen off often stops answering
            // Bonjour, and then each attempt failed for minutes (26 Sep 2026). Bonjour only when
            // no address answers, for example when the router gave the phone a new address.
            func tailscale(_ address: String) -> Bool { Reach.split(address).map { Reach.isTailscale($0.host) } ?? false }
            var direct: String?
            for address in settings.babyAddresses.sorted(by: { !tailscale($0) && tailscale($1) }) {
                guard let a = Reach.split(address), await Reach.canConnect(host: a.host, port: a.port) else { continue }
                direct = address
                break
            }
            if settings.babyDirect != direct { settings.babyDirect = direct }
            let isTailscale = direct.map(tailscale) ?? false
            if viaTailscale != isTailscale { viaTailscale = isTailscale }
        }
    }

    /// This phone has a Tailscale address, and the camera is not on the phone's own network (/24).
    nonisolated static func cameraOverTailscale(host: String, local: [String]) -> Bool {
        guard local.contains(where: Reach.isTailscale), networkPrefix(host) != nil else { return false }
        return !onOwnNetwork(host: host, local: local)
    }

    /// The camera's address is on the same /24 as one of this phone's private addresses.
    nonisolated static func onOwnNetwork(host: String, local: [String]) -> Bool {
        func isPrivate(_ ip: String) -> Bool {
            let p = ip.split(separator: ".").compactMap { Int($0) }
            guard p.count == 4 else { return false }
            return p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
        }
        guard let camera = networkPrefix(host) else { return false }
        return local.contains { isPrivate($0) && networkPrefix($0) == camera }
    }

    /// "192.168.0.197" to "192.168.0". Nil for a name or an IPv6 address.
    nonisolated private static func networkPrefix(_ ip: String) -> String? {
        let parts = ip.trimmingCharacters(in: .whitespaces).split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return nil }
        return parts.prefix(3).joined(separator: ".")
    }

    // These closures run on the RTSP queue. They are nonisolated, so they never touch the main actor.

    nonisolated private static func levelSink(_ shared: OSAllocatedUnfairLock<Shared>) -> (Float) -> Void {
        { level in shared.withLock { $0.peak = max($0.peak, level) } }
    }

    nonisolated private static func verdictSink(engine: MonitorEngine) -> CryDetector.VerdictSink {
        { [weak engine] verdict in
            Task { @MainActor in engine?.cryVerdict(verdict) }
        }
    }

    nonisolated private static func cryFailureSink(engine: MonitorEngine) -> CryDetector.FailureSink {
        { [weak engine] why in
            Task { @MainActor in engine?.cryClassifierFailed(why) }
        }
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
                    let draw = shared.withLock { s -> Bool in
                        s.lastVideo = now
                        s.lastPacket = now
                        return s.renderVideo
                    }
                    // Nothing shows the picture (the sound view, Night mode, the background):
                    // do not even assemble the frames. When the drawing starts again, the gap in
                    // the sequence makes the depacketizer wait for the next keyframe.
                    guard draw, let unit = depacketizer.push(packet) else { return }
                    renderer.render(unit, depacketizer: depacketizer)
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

    private func connected(_ gen: Int, _ tracks: [RTSPClient.Track], reported: [String]) {
        guard gen == generation else { return }
        // The phone at the baby tells its addresses. Keep them for the time away from home.
        if settings.source == .phone, !reported.isEmpty, reported != settings.babyAddresses {
            settings.babyAddresses = reported
            Log.shared.add("baby phone addresses: \(reported.joined(separator: ", "))")
        }
        let names = tracks.map { "\($0.sdp.kind.rawValue) \($0.sdp.codec)" }.joined(separator: ", ")
        Log.shared.add("playing: \(names)")
        connection = .live
        retryDelay = 1
        failures = 0
    }

    private func connectionEnded(_ gen: Int, _ error: Error?) {
        // onClose and the thrown error both report the same end. Count it one time.
        guard gen == generation, client != nil else { return }
        client = nil
        let message = (error as? LocalizedError)?.errorDescription ?? error?.localizedDescription ?? "Spojení se ukončilo."
        Log.shared.add("connection ended: \(message)")
        failures += 1
        pictureLive = false
        let delay: Double
        if case .cameraFull? = error as? RTSPClient.Failure {
            // Other phones hold the camera's sessions. A fast retry only takes a slot again and
            // again, so wait a fixed 15 s, and keep the backoff as it is.
            connection = .retrying(message)
            delay = 15
            Log.shared.add("camera full, retry in 15 s")
        } else {
            connection = .retrying(awayHint(message))
            delay = retryDelay
            // In the background, after a long outage (the camera is off for the night), try every 30 s,
            // not every 8 s: each try wakes the Wi-Fi radio. In the foreground, 8 s at most.
            retryDelay = min(retryDelay * 2, !isForeground && failures >= 10 ? 30 : 8)
        }
        let relocate = shouldRelocate(after: error)
        if relocate { lastRelocation = Date() }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            if relocate, let self {
                let found = await CameraFinder.relocate(settings: self.settings)
                guard !Task.isCancelled, gen == self.generation else { return }
                if let host = found, host != self.settings.rtspHost {
                    self.settings.rtspHost = host
                    Log.shared.add("camera moved to \(host)")
                    self.notice = "Kamera nalezena na nové adrese"
                    self.reconnect(why: "camera moved")
                    return
                }
            }
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.connect()
        }
    }

    // MARK: A camera at a new address

    /// The last search for a camera that moved. At most one search per 60 s.
    private var lastRelocation = Date.distantPast

    /// The router gave the camera a new address: the saved one does not answer at all. Search the
    /// home network after the second failure, in the foreground or in picture in picture only
    /// (the scan wakes the Wi-Fi radio for about 3 s). Not for a full camera or a wrong password:
    /// those answer at the saved address. Also on another network than the saved address: on a
    /// trip the camera hangs on the phone's own hotspot (172.20.10.x) and gets a new address there.
    private func shouldRelocate(after error: Error?) -> Bool {
        guard settings.source == .camera, settings.cameraKind == .rtsp, settings.rtspBrand != .other,
              failures >= 2, isForeground || pip.isActive,
              Date().timeIntervalSince(lastRelocation) > 60 else { return false }
        switch error as? RTSPClient.Failure {
        case .unreachable?, .timeout?: return true
        default: return false
        }
    }

    /// Away from home with no way in: say what helps.
    private func awayHint(_ message: String) -> String {
        guard failures >= 1 else { return message }
        switch settings.source {
        case .camera where settings.cameraKind == .rtsp:
            return message + " Mimo domov to funguje jen přes domácí Tailscale (Nastavení → Pro pokročilé → Mimo domov)."
        case .camera where settings.trimmedRemoteHost.isEmpty:
            return message + " Mimo domov zadejte v Nastavení adresu přes Tailscale."
        case .camera:
            return message + " Mimo domov zapněte v telefonu Tailscale."
        case .phone where !settings.babyAddresses.contains(where: { Reach.split($0).map { Reach.isTailscale($0.host) } ?? false }):
            return message + " Mimo domov: nainstalujte Tailscale i na telefon u miminka a jednou se k němu připojte doma."
        case .phone:
            return message + " Mimo domov zapněte Tailscale na obou telefonech."
        }
    }

    // MARK: The sound

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .playback: the sound continues on the lock screen and with the silent switch on.
            // .mixWithOthers: another app's sound (a video, music, a voice message) plays together
            // with the monitor. Without it, that app interrupted the monitor, the engine stopped,
            // iOS then suspended the app in the background, and nobody listened (26 Sep 2026).
            // The cost: iOS shows no Now Playing controls for a mixable app. A call still interrupts.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            // 40 ms audio buffers: fewer wake-ups of the audio thread than the default 5-10 ms.
            // The jitter cushion (80-400 ms) is far larger, so the delay does not change noticeably.
            try? session.setPreferredIOBufferDuration(0.04)
            // An incoming-call banner does not interrupt the sound (a full-screen call still does).
            try session.setPrefersNoInterruptionsFromSystemAlerts(true)
            try session.setActive(true)
        } catch {
            Log.shared.add("audio session: \(error.localizedDescription)")
        }
        // The volume buttons, Control Center, and a new route (AirPods) all change it.
        systemVolume = session.outputVolume
        volumeObservation = session.observe(\.outputVolume, options: [.new]) { [weak self] s, _ in
            let v = s.outputVolume
            Task { @MainActor in self?.volumeChanged(v) }
        }
    }

    private func volumeChanged(_ v: Float) {
        let wasLow = volumeLow
        systemVolume = v
        if volumeLow != wasLow { Log.shared.add("iPhone volume \(Int(v * 100)) %") }
    }

    private func applyMode() {
        guard !Self.isDemo else { updateStatus(force: true); return }
        guard !suspended else { return }
        activateAudioSession()
        audio.start()
        // Muted plays the stream at zero volume. The app stays awake, hears the room, and warns about a cry.
        audio.setMuted(mode == .off)
        alerted = false
        if mode == .off { NurseryAlerts.requestPermission() }
        updateStatus(force: true)
        if !isForeground { enterBackgroundMode() }
        if !isForeground, client == nil { reconnect(why: "sound mode changed in the background") }
    }

    /// It returns a full frame from go2rtc. The app sets it (CameraControl.snapshot).
    var snapshotProvider: (() async -> UIImage?)?

    /// An episode starts in the room. Keep a photo of the moment, and tell the parent when the
    /// parent may not hear it: the sound muted, the iPhone volume low, or the sound alert on.
    /// Also with the app open, for example in Night mode on the night table.
    private func episodeStarted(_ episode: SoundActivity.Episode) {
        Log.shared.add(String(format: "sound episode, level %.2f, floor %.2f", episode.peak, activityLog.noiseFloor))
        if let snapshotProvider {
            Task {
                // Wait a moment: the photo then shows the baby during the sound, not before it.
                try? await Task.sleep(for: .seconds(1.5))
                guard let image = await snapshotProvider() else { return }
                // Scale and JPEG-encode off the main thread: about 0.1 s of work.
                let id = episode.id
                await Task.detached(priority: .utility) { Moments.save(image, for: id) }.value
            }
        }
        let unheard = mode == .off || volumeLow
        let wanted = unheard || settings.alertOnSound
        // With live sound at a good volume, the parent hears it. An alert on the open app is noise then.
        let appOpen = UIApplication.shared.applicationState == .active
        guard wanted, !(appOpen && !unheard), Date().timeIntervalSince(lastSoundAlert) > 60 else { return }
        lastSoundAlert = Date()
        NurseryAlerts.postSound(at: episode.start)
    }

    // MARK: Night mode

    /// Night mode: the screen is almost black, so the picture is not needed.
    /// The app then asks for the sound only, as in the background. This saves the battery.
    @Published private(set) var nightMode = false

    func setNightMode(_ on: Bool) {
        guard on != nightMode else { return }
        nightMode = on
        Log.shared.add(on ? "night mode on" : "night mode off")
        // Night mode takes the picture off the screen, so a swipe home opens no small window.
        pip.automatic = !on && !settings.soundView
        applyPicture(why: on ? "night mode: sound only" : "night mode off")
    }

    // MARK: The sound view

    /// The sound view: the parent chose to only listen. The screen shows the room, not the picture,
    /// so the app asks go2rtc for the sound only. That saves the battery, the Wi-Fi, and the heat.
    func setSoundView(_ on: Bool) {
        guard on != settings.soundView else { return }
        settings.soundView = on
        Log.shared.add(on ? "sound view" : "picture view")
        pip.automatic = !on && !nightMode    // With no picture, a swipe home must not open an empty small window.
        applyPicture(why: on ? "sound view: sound only" : "picture view")
    }

    /// It starts or stops the picture after Night mode or the sound view changes.
    private func applyPicture(why: String) {
        let render = wantsPicture || pip.isActive
        shared.withLock { $0.renderVideo = render }
        if Self.isDemo { audioOnly = !render; return }
        guard isForeground else { return }
        if render { client?.queue.async { [renderer] in renderer.reset() } }
        updateStream(why: why)
    }

    /// The URL of the current stream, to see if a change of view needs a new one.
    private var currentURL: String?

    /// A new stream only when the wanted one differs. With the camera, the small picture, the sound
    /// view, Night mode and the background can all use the same sub stream: then only the drawing
    /// changes, with no reconnect, no gap in the sound, and no new handshake.
    private func updateStream(why: String) {
        let wanted = wantsAudioOnly
        guard client == nil || (wanted != audioOnly && streamURL(audioOnly: wanted) != currentURL) else {
            audioOnly = wanted
            return
        }
        reconnect(why: why)
    }

    /// The stream to ask for, as `StreamPolicy` decides: the main stream only for a big picture
    /// on a phone that is not hot and not in Low Power Mode. Sound only is always the sub stream.
    private func stream(audioOnly: Bool) -> (url: String, detail: Bool) {
        let names = settings.streamNames
        let inputs = StreamPolicy.Inputs(wantsDetail: wantsDetail, soundOnly: audioOnly, thermalHot: thermalHot,
                                         lowPower: lowPower, detailStream: names.detail, everydayStream: names.everyday)
        let detail = StreamPolicy.detail(inputs)
        return (settings.streamURL(audioOnly: audioOnly, small: !detail), detail)
    }

    private func streamURL(audioOnly: Bool) -> String { stream(audioOnly: audioOnly).url }

    /// The main stream plays now. For the "Stav" row in the settings.
    @Published private(set) var detailActive = false {
        didSet { Self.liveDetail = detailActive }
    }

    /// The live connection uses the main (detail) stream. A photo from a direct camera then reads
    /// the sub stream, else the main stream: never a second session on the path that plays. The
    /// camera serves at most 3 sessions per path (Tapo), and a few phones already hold some.
    /// Static, because CameraControl has no engine.
    static private(set) var liveDetail = false

    /// A new stream if the wanted URL changed (detail, heat or Low Power Mode), with the same view.
    private func refreshStream(why: String) {
        if client != nil, streamURL(audioOnly: audioOnly) != currentURL { reconnect(why: why) }
    }

    // MARK: Detail

    /// The screen shows the picture big: zoomed in, full screen, or on an iPad.
    private var wantsDetail = false
    private var detailTask: Task<Void, Never>?

    /// Up to the main stream after 0.6 s (the pinch has settled). Back to the sub stream only
    /// after 10 s, so a short zoom out and in again does not switch twice. Each switch is a
    /// reconnect: the sound pauses for about a second, and the picture holds its last frame
    /// until the next keyframe.
    func setDetail(_ on: Bool) {
        detailTask?.cancel()
        detailTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(on ? 0.6 : 10))
            guard let self, !Task.isCancelled, self.wantsDetail != on else { return }
            self.wantsDetail = on
            self.refreshStream(why: on ? "detail: main stream" : "no detail: sub stream")
        }
    }

    // MARK: Heat

    /// The phone is hot (thermal state serious or critical). The app then asks for the sub stream
    /// instead of the main stream, which cuts the Wi-Fi and the decoder work, until it cools down.
    private(set) var thermalHot = false

    private func thermalChanged() {
        let state = ProcessInfo.processInfo.thermalState
        let hot = state == .serious || state == .critical
        guard hot != thermalHot else { return }
        thermalHot = hot
        Log.shared.add("thermal state \(state.rawValue): \(hot ? "sub stream until the phone cools" : "normal picture")")
        refreshStream(why: "thermal state changed")
    }

    // MARK: Low Power Mode

    /// Low Power Mode is on. The app then asks for the sub stream, as for a hot phone.
    private(set) var lowPower = false

    private func lowPowerChanged() {
        let on = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard on != lowPower else { return }
        lowPower = on
        Log.shared.add("low power mode \(on ? "on: sub stream" : "off: normal picture")")
        refreshStream(why: "low power mode changed")
    }

    private func audioInterrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt ?? 0
            Log.shared.add("sound interrupted, reason \(reason)")   // 1 = the app was suspended.
            audio.setInterrupted(true)
            recoverSound()
        case .ended:
            // A monitor resumes always, also without the "should resume" option.
            Log.shared.add("sound interruption ended")
            endRecovery()
            NurseryAlerts.clearInterrupted()
            activateAudioSession()
            audio.setInterrupted(false)
            audio.start()
            audio.setMuted(mode == .off)
        @unknown default:
            break
        }
    }

    // MARK: Taking the sound back

    private var recoveryTask: Task<Void, Never>?
    private var recoveryBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// Siri, an alarm or an app that wants the sound only for itself interrupted the monitor.
    /// Do not wait for "interruption ended": many apps never send it. Try to take the sound back:
    /// each 2 s for the first 30 s, then each 10 s, for 5 minutes. A call refuses the tries, and
    /// "interruption ended" after the call starts the sound again.
    ///
    /// In the background, iOS gives an app with no sound only about 30 s (a background task),
    /// then it suspends the app. Just before that, tell the parent at once, clearly, instead of
    /// the watchdog's vague "stopped watching" 2.5 minutes later.
    private func recoverSound() {
        guard !suspended, !Self.isDemo else { return }
        recoveryTask?.cancel()
        if recoveryBackgroundTask == .invalid {
            recoveryBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "sound recovery") { [weak self] in
                MainActor.assumeIsolated { self?.backgroundTimeEnded() }
            }
        }
        recoveryTask = Task { [weak self] in
            let start = Date()
            while Date().timeIntervalSince(start) < 300 {
                let elapsed = Date().timeIntervalSince(start)
                try? await Task.sleep(for: .seconds(elapsed < 30 ? 2 : 10))
                guard let self, !Task.isCancelled else { return }
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                } catch {
                    continue            // The other sound still has priority. Try again.
                }
                Log.shared.add("sound taken back after \(Int(Date().timeIntervalSince(start))) s")
                self.audio.setInterrupted(false)
                self.audio.start()
                self.audio.setMuted(self.mode == .off)
                NurseryAlerts.clearInterrupted()
                break
            }
            self?.endRecovery()
        }
    }

    /// iOS ends the background time now, and the sound is not back. The app gets suspended.
    private func backgroundTimeEnded() {
        Log.shared.add("sound not back before iOS suspends the app")
        NurseryAlerts.postInterrupted()
        // The watchdog would say the same, less clearly, 2.5 minutes later. When "interruption
        // ended" wakes the app, the sound starts again and the tick arms the watchdog again.
        NurseryAlerts.disarmWatchdog()
        endRecovery()
    }

    private func endRecovery() {
        recoveryTask?.cancel()
        recoveryTask = nil
        if recoveryBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(recoveryBackgroundTask)
            recoveryBackgroundTask = .invalid
        }
    }

    // MARK: The clock (10 Hz)

    private func tick() {
        guard !suspended else { return }
        ticks += 1
        let now = Date()
        let s = shared.withLock { state -> Shared in
            let copy = state
            state.peak = 0
            return copy
        }

        // Fast attack, slow release. This is how a VU meter moves.
        let raw = Self.isDemo ? demoLevel() : s.peak
        let target = raw
        let smoothed = target > meter ? target : meter * 0.82 + target * 0.18
        meter = smoothed
        // Change the published values only while a screen shows them. Each change makes SwiftUI
        // redraw the monitor. In the background that cost 100 % of a core, and iOS killed the app
        // after 48 s ("cpu usage, 80 % over 60 s", 25 Sep 2026).
        let visible = isForeground || pip.isActive
        if visible { levels.push(smoothed) }

        if soundStatus == .listening || soundStatus == .silent {
            activityLog.feed(level: smoothed, at: now)
        }
        // The cry classifier listens only while a sound event runs. Only a change costs anything.
        let wantCry = !Self.isDemo && classifierAvailable && activityLog.current != nil
        if wantCry != cryListening { setCryListening(wantCry) }
        holdRoomLevel(RoomLevel(smoothed), now: now)

        guard ticks % 5 == 0 else { return }       // The rest runs at 2 Hz.
        let live = now.timeIntervalSince(s.lastVideo) < 3
        if live != pictureLive { pictureLive = live }
        let delay = Int(audio.bufferedSeconds * 1000)
        if visible, delay != delayMilliseconds { delayMilliseconds = delay }
        if now.timeIntervalSince(s.lastAudio) < 3 { everHeard = true }

        // A half-open TCP connection gives no error. Detect it by the silence of the data.
        if connection == .live, now.timeIntervalSince(s.lastPacket) > 6 {
            reconnect(why: "no data for 6 s")
        }
        updateStatus(force: false, lastAudio: s.lastAudio)
        updateRoomState(now: now)

        audio.heal()
        // The watchdog: while the app runs in the background, keep the "stopped" alert 150 s away.
        if !isForeground, !Self.isDemo, now.timeIntervalSince(lastWatchdog) >= 30 {
            lastWatchdog = now
            NurseryAlerts.armWatchdog()
        }
        // A sign of life each 5 minutes in the background. A gap in the log shows a stop by iOS.
        if !isForeground, now.timeIntervalSince(lastAlive) >= 300 {
            // The processor share since the last line. iOS kills a background app above 80 %.
            let cpu = Self.processCPUSeconds()
            let share = (cpu - lastAliveCPU) / now.timeIntervalSince(lastAlive) * 100
            lastAlive = now
            lastAliveCPU = cpu
            Log.shared.add(String(format: "alive in the background, audio engine %@, %@, CPU %.0f %%",
                                  audio.isRunning ? "on" : "OFF", soundStatus.rawValue, share))
        }
    }

    /// A louder word shows when the room stays louder for 0.4 s, whatever the louder word is.
    /// A quieter word shows when the room stays quieter for 2.5 s.
    private func holdRoomLevel(_ next: RoomLevel, now: Date) {
        if next > roomLevel {
            quieterSince = nil
            if louderSince == nil { louderSince = now }
            if let since = louderSince, now.timeIntervalSince(since) >= 0.4 {
                roomLevel = next
                louderSince = nil
            }
        } else if next < roomLevel {
            louderSince = nil
            if quieterSince == nil { quieterSince = now }
            if let since = quieterSince, now.timeIntervalSince(since) >= 2.5 {
                roomLevel = next
                quieterSince = nil
            }
        } else {
            louderSince = nil
            quieterSince = nil
        }
    }

    // MARK: The cry classifier

    private func setCryListening(_ on: Bool) {
        guard on != cryListening else { return }
        cryListening = on
        audio.setSamplesWanted(on)
        cry.setActive(on)
    }

    /// A verdict for one window of sound, at most twice a second. The detector logs it.
    private func cryVerdict(_ verdict: CryVerdict) {
        guard cryListening, activityLog.current != nil else { return }      // A late one after the event.
        roomMachine.classified(verdict)
        activityLog.markCurrentClassified()
    }

    /// The model did not load, or it failed. From now on the loudness rule decides.
    private func cryClassifierFailed(_ why: String) {
        guard classifierAvailable else { return }
        classifierAvailable = false
        setCryListening(false)
        Log.shared.add("cry classifier not available (\(why)): the loudness rule decides")
    }

    /// The word of the room, from the signals the engine has. Published only when it changes.
    private func updateRoomState(now: Date) {
        let next: RoomState
        if Self.isDemo {
            guard Self.demoRoomState == nil else { return }       // Set once in startDemo().
            next = meter > 0.35 ? .sound : .calm
        } else {
            let event = activityLog.current
            let input = RoomStateMachine.Input(
                heard: soundStatus == .listening || soundStatus == .silent,
                everHeard: everHeard,
                eventRunning: event != nil,
                eventSeconds: event?.duration ?? 0,
                eventPeak: event?.peak ?? 0,
                level: meter,
                loudLevel: max(activityLog.threshold + 0.15, 0.45),
                classifierAvailable: classifierAvailable)
            next = roomMachine.update(input, now: now)
            // Přehled calls the episode "Pláč" iff the word was "Pláče" during it.
            if next == .cry, event != nil { activityLog.markCurrentCried() }
        }
        guard next != roomState else { return }
        roomState = next
        roomStateSince = Self.isDemo ? now : roomMachine.since ?? now
        Log.shared.add("room: \(next.title)")
    }

    private func updateStatus(force: Bool, lastAudio: Date? = nil) {
        let heardRecently = Date().timeIntervalSince(lastAudio ?? shared.withLock { $0.lastAudio }) < 3
        let status: SoundStatus
        if heardRecently { status = mode == .off ? .silent : .listening }
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
            if !alerted, let since = lostSince, Date().timeIntervalSince(since) > 20 {
                alerted = true
                NurseryAlerts.postLoss()
            }
        } else {
            lostSince = nil
            if alerted, status == .listening || status == .silent { alerted = false; NurseryAlerts.clearLoss() }
        }

        guard !Self.isDemo else { return }
        activity.update(status: status, enabled: true)
    }
}

/// The loudness for the meters: the waveform, the orb and the glow. It is a separate object
/// because it changes 10 times a second. Only the views that draw it watch it, so a change
/// does not make SwiftUI rebuild the whole monitor with its charts and glass panels.
@MainActor
final class LevelMeter: ObservableObject {
    /// The last 6 seconds, oldest first. One value each 0.1 s.
    @Published private(set) var history: [Float] = Array(repeating: 0, count: 60)
    var level: Float { history.last ?? 0 }

    func push(_ value: Float) {
        var h = history
        h.removeFirst()
        h.append(value)
        history = h          // One change, one redraw.
    }
}
