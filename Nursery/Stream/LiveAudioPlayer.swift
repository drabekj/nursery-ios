import AVFoundation
import os

/// It plays the G.711 audio of the camera with a small, bounded delay.
///
/// The latency rule: keep 80 to 400 ms of audio in the queue. Above the limit, drop packets.
/// Thus a network stall never adds a permanent delay. A Safari stream cannot do this.
///
/// The threading rule: every call to the engine and the player node runs on one serial queue.
/// An engine call from two threads at once can raise an Objective-C exception, which crashes the app.
/// In the background that looks exactly like "the app stopped".
final class LiveAudioPlayer: @unchecked Sendable {
    /// The level of the room, 0...1, before the gain. It runs on the caller's queue.
    var onLevel: ((Float) -> Void)?
    /// The decoded samples, -1...1, before the gain: the input of the cry detector. Set it once,
    /// before the stream starts. It runs on the caller's queue, only while `setSamplesWanted(true)`.
    var onSamples: (([Float]) -> Void)?

    private let q = DispatchQueue(label: "nursery.audio", qos: .userInteractive)
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    /// Float32, mono, at the stream's rate (8000 Hz for G.711).
    let format: AVAudioFormat
    private let sampleRate: Double
    private let startFrames: Int
    private let maxFrames: Int

    // Only `q` touches these.
    private var wantRunning = false
    private var interrupted = false
    private var priming = true
    private var gain: Float = 1
    private var muted = false
    private var lastHeal = Date.distantPast
    private var observer: NSObjectProtocol?

    // Read from other threads.
    private let queuedFrames = OSAllocatedUnfairLock(initialState: 0)
    private let engineRunning = OSAllocatedUnfairLock(initialState: false)
    private let samplesWanted = OSAllocatedUnfairLock(initialState: false)

    init(sampleRate: Double = 8000) {
        self.sampleRate = sampleRate
        startFrames = Int(sampleRate * 0.12)
        maxFrames = Int(sampleRate * 0.40)
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        q.sync { buildGraph() }
    }

    // MARK: The public calls. Each one goes to the queue.

    /// The gain in dB. The phone buttons set the output level. This makes a quiet room audible.
    func setGain(decibels: Float) {
        let g = powf(10, decibels / 20)
        q.async { self.gain = g }
    }

    /// Silent mode: the stream plays at zero volume. The meter still works.
    func setMuted(_ m: Bool) {
        q.async {
            self.muted = m
            self.player.volume = m ? 0 : 1
        }
    }

    func start() {
        q.async {
            self.wantRunning = true
            self.startEngine()
        }
    }

    func stop() {
        q.async {
            self.wantRunning = false
            self.stopEngine()
        }
    }

    /// A phone call, Siri, or an alarm stops the engine. Do not try to restart it until the end.
    func setInterrupted(_ value: Bool) {
        q.async {
            self.interrupted = value
            if value { self.stopEngine() } else if self.wantRunning { self.startEngine() }
        }
    }

    /// It restarts the engine if it stopped behind our back. The monitor calls it twice a second.
    func heal() {
        q.async {
            guard self.wantRunning, !self.interrupted, !self.engine.isRunning,
                  Date().timeIntervalSince(self.lastHeal) > 2 else { return }
            self.lastHeal = Date()
            Log.shared.add("audio engine is not running: restart")
            self.stopEngine()
            self.startEngine()
        }
    }

    /// After "media services were reset", the old engine and node are dead. Build new ones.
    func recreate() {
        q.async {
            Log.shared.add("audio engine rebuilt")
            self.stopEngine()
            if let observer = self.observer { NotificationCenter.default.removeObserver(observer) }
            self.engine = AVAudioEngine()
            self.player = AVAudioPlayerNode()
            self.buildGraph()
            if self.wantRunning, !self.interrupted { self.startEngine() }
        }
    }

    var isRunning: Bool { engineRunning.withLock { $0 } }

    /// The cry detector listens: hand the samples to `onSamples`. Off in a quiet room, so the
    /// decoding for it costs nothing then.
    func setSamplesWanted(_ on: Bool) { samplesWanted.withLock { $0 = on } }

    /// The current delay of the queue, in seconds.
    var bufferedSeconds: Double { Double(queuedFrames.withLock { $0 }) / sampleRate }

    /// It decodes one RTP payload and plays it.
    func enqueue(payload: ArraySlice<UInt8>, uLaw: Bool) {
        let table = uLaw ? G711.uLaw : G711.aLaw
        guard !payload.isEmpty else { return }

        // The level of the room, from the raw samples, on the caller's queue.
        let tap = samplesWanted.withLock { $0 } ? onSamples : nil
        var samples: [Float] = []
        if tap != nil { samples.reserveCapacity(payload.count) }
        var sum: Float = 0
        for byte in payload {
            let s = Float(table[Int(byte)]) / 32768
            sum += s * s
            if tap != nil { samples.append(s) }
        }
        onLevel?(Self.level(fromRMS: sqrtf(sum / Float(payload.count))))
        tap?(samples)

        let bytes = Array(payload)
        q.async { self.schedule(bytes, table: table) }
    }

    /// It maps the RMS to 0...1 on a dB scale. -58 dBFS is silence, and -12 dBFS is a cry.
    static func level(fromRMS rms: Float) -> Float {
        let db = 20 * log10f(max(rms, 1e-6))
        return min(1, max(0, (db + 58) / 46))
    }

    // MARK: The queue-only work

    private func buildGraph() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: nil) { [weak self] _ in
            // A route change (for example headphones) stops the engine. Start it again, on the queue.
            guard let self else { return }
            self.q.async {
                Log.shared.add("audio configuration changed")
                self.stopEngine()
                if self.wantRunning, !self.interrupted { self.startEngine() }
            }
        }
    }

    private func startEngine() {
        guard wantRunning, !interrupted, !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            Log.shared.add("audio engine did not start: \(error.localizedDescription)")
            engineRunning.withLock { $0 = false }
            return
        }
        player.volume = muted ? 0 : 1
        queuedFrames.withLock { $0 = 0 }
        priming = true              // The player starts when the cushion is full.
        engineRunning.withLock { $0 = true }
    }

    private func stopEngine() {
        player.stop()
        engine.stop()
        queuedFrames.withLock { $0 = 0 }
        priming = true
        engineRunning.withLock { $0 = false }
    }

    private func schedule(_ bytes: [UInt8], table: [Int16]) {
        // A stopped engine: play() would raise an exception. Wait for heal() instead.
        guard wantRunning, engine.isRunning else { return }
        let count = bytes.count
        let queued = queuedFrames.withLock { $0 }
        if queued > maxFrames { return }                   // Too late. Drop it to catch up.
        if queued == 0, !priming {                         // An underrun. Collect a new cushion.
            priming = true
            player.pause()
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let out = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        let g = gain
        for (i, byte) in bytes.enumerated() {
            let s = Float(table[Int(byte)]) / 32768 * g
            out[i] = g > 1 ? tanhf(s) : s                   // A soft limit. No hard clipping.
        }
        queuedFrames.withLock { $0 += count }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.queuedFrames.withLock { $0 = max(0, $0 - count) }
        }
        if priming, queuedFrames.withLock({ $0 }) >= startFrames {
            priming = false
            player.play()
        }
    }
}
