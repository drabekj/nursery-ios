import AVFoundation
import os

/// It plays the G.711 audio of the camera with a small, bounded delay.
///
/// The latency rule: keep 80 to 400 ms of audio in the queue. Above the limit, drop packets.
/// Thus a network stall never adds a permanent delay. A Safari stream cannot do this.
final class LiveAudioPlayer: @unchecked Sendable {
    /// The level of the room, 0...1, before the gain. It runs on the RTSP queue.
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private let lock = OSAllocatedUnfairLock(initialState: 0)   // The queued frames.
    private var priming = true
    private var gain: Float = 1
    private var running = false

    private let startFrames: Int
    private let maxFrames: Int
    private let sampleRate: Double

    init(sampleRate: Double = 8000) {
        self.sampleRate = sampleRate
        startFrames = Int(sampleRate * 0.12)
        maxFrames = Int(sampleRate * 0.40)
        engine.attach(player)
        NotificationCenter.default.addObserver(self, selector: #selector(configurationChanged),
                                               name: .AVAudioEngineConfigurationChange, object: engine)
    }

    /// The gain in dB. The phone buttons set the output level. This makes a quiet room audible.
    func setGain(decibels: Float) {
        gain = powf(10, decibels / 20)
    }

    func start() {
        guard !running else { return }
        do {
            let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
            format = fmt
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: fmt)
            engine.prepare()
            try engine.start()
            lock.withLock { $0 = 0 }
            running = true
            priming = true        // The player starts when the cushion is full.
        } catch {
            Log.shared.add("audio engine did not start: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard running else { return }
        player.stop()
        engine.stop()
        running = false
        lock.withLock { $0 = 0 }
    }

    var isRunning: Bool { running && engine.isRunning }

    /// The current delay of the queue, in seconds.
    var bufferedSeconds: Double { Double(lock.withLock { $0 }) / sampleRate }

    /// It decodes one RTP payload and plays it.
    func enqueue(payload: ArraySlice<UInt8>, uLaw: Bool) {
        let table = uLaw ? G711.uLaw : G711.aLaw
        let count = payload.count
        guard count > 0 else { return }

        // The level of the room, from the raw samples.
        var sum: Float = 0
        for byte in payload {
            let s = Float(table[Int(byte)]) / 32768
            sum += s * s
        }
        let rms = sqrtf(sum / Float(count))
        onLevel?(Self.level(fromRMS: rms))

        // A phone call stops the engine. play() on a stopped engine throws an exception.
        guard running, engine.isRunning, let format else { return }
        let queued = lock.withLock { $0 }
        if queued > maxFrames { return }                   // Too late. Drop it to catch up.
        if queued == 0, !priming {                         // An underrun. Collect a new cushion.
            priming = true
            player.pause()
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let out = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        let g = gain
        var i = 0
        for byte in payload {
            let s = Float(table[Int(byte)]) / 32768 * g
            out[i] = g > 1 ? tanhf(s) : s                   // A soft limit. No hard clipping.
            i += 1
        }
        lock.withLock { $0 += count }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.lock.withLock { $0 = max(0, $0 - count) }
        }
        if priming, lock.withLock({ $0 }) >= startFrames {
            priming = false
            player.play()
        }
    }

    /// It maps the RMS to 0...1 on a dB scale. -58 dBFS is silence, and -12 dBFS is a cry.
    static func level(fromRMS rms: Float) -> Float {
        let db = 20 * log10f(max(rms, 1e-6))
        return min(1, max(0, (db + 58) / 46))
    }

    @objc private func configurationChanged(_ note: Notification) {
        // A route change (for example headphones) stops the engine. Start it again.
        Log.shared.add("audio route changed")
        running = false
        start()
    }
}
