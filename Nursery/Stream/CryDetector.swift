import AVFoundation
import os
import SoundAnalysis

/// It listens for a baby cry in the sound of the room, with the sound classifier that is built
/// into iOS (SoundAnalysis, version 1: about 300 kinds of sound, on the phone, no network).
///
/// The rules:
/// - It runs only while a sound event runs (`SoundActivity.current != nil`). In a quiet room it
///   does nothing: no decoding for it, no analysis, no processor time.
/// - Windows of 1 s, half overlapping: at most one verdict each 0.5 s. Each verdict goes to the
///   main actor and into the log ("cry: baby_crying 0.82", "cry: other speech 0.61").
/// - If the model does not load or fails, it says so once, and the engine uses the loudness rule.
///
/// The input is the G.711 sound of the camera or the phone: 8000 Hz, telephone quality. The model
/// was trained on 16 kHz sound. The analyzer converts the rate, but the top half of the spectrum
/// is missing, so the model may be less sure about a cry. The log lines are the tool to measure
/// it on a phone.
///
/// The threading rule: all state lives on one serial queue `q`. The samples come from the RTSP
/// queue, the switch from the main actor, and the verdicts go to the main actor.
final class CryDetector: @unchecked Sendable {
    /// The verdict for one window. It runs on the analyzer's thread: hop to the main actor.
    typealias VerdictSink = @Sendable (CryVerdict) -> Void
    /// The classifier cannot run. It runs once, on the detector's queue.
    typealias FailureSink = @Sendable (String) -> Void

    /// The identifiers of the classifier. `CryDetectorTests` checks that they exist.
    static let babyCrying = "baby_crying"
    static let cryingSobbing = "crying_sobbing"
    /// The confidence at which a baby cry counts even when another sound is on top. The classifier
    /// gives each sound its own confidence (they do not add up to 1), so a cry with speech can be second.
    static let babyCryingConfidence: Float = 0.5
    /// "Crying, sobbing" is also an adult: it counts only when it is on top and quite sure.
    static let cryingSobbingConfidence: Float = 0.6

    private let q = DispatchQueue(label: "nursery.cry", qos: .utility)
    private let format: AVAudioFormat
    /// Half a second of sound per call to the analyzer.
    private let chunk: AVAudioFrameCount

    // Only `q` touches these.
    private var verdictSink: VerdictSink?
    private var failureSink: FailureSink?
    private var request: SNClassifySoundRequest?
    private var analyzer: SNAudioStreamAnalyzer?
    private var observer: Observer?
    private var pending: AVAudioPCMBuffer?
    private var position: AVAudioFramePosition = 0
    private var active = false
    private var broken = false

    init(format: AVAudioFormat) {
        self.format = format
        chunk = AVAudioFrameCount(max(1, format.sampleRate / 2))
    }

    /// Set once, before the first `setActive(true)`.
    func setSinks(verdict: @escaping VerdictSink, failure: @escaping FailureSink) {
        q.async {
            self.verdictSink = verdict
            self.failureSink = failure
        }
    }

    /// On at the start of a sound event, off at its end. The engine calls it.
    func setActive(_ on: Bool) {
        q.async { on ? self.start() : self.stop() }
    }

    /// Decoded samples, -1...1, from the RTSP queue. Ignored while the detector is off.
    func feed(_ samples: [Float]) {
        q.async { self.append(samples) }
    }

    /// The verdict for one window: the top sound, or a baby cry. Pure, for the tests.
    /// `classifications` is (identifier, confidence), in any order.
    static func verdict(_ classifications: [(String, Float)]) -> CryVerdict {
        guard let top = classifications.max(by: { $0.1 < $1.1 }) else { return .other("nothing", 0) }
        if top.0 == babyCrying { return .cry(top.1) }
        if top.0 == cryingSobbing, top.1 >= cryingSobbingConfidence { return .cry(top.1) }
        if let baby = classifications.first(where: { $0.0 == babyCrying }), baby.1 >= babyCryingConfidence {
            return .cry(baby.1)
        }
        return .other(top.0, top.1)
    }

    // MARK: The queue-only work

    private func start() {
        guard !active, !broken else { return }
        do {
            let request = try self.request ?? makeRequest()
            self.request = request
            // A new analyzer for each event: its frame positions start at 0, and a verdict of an
            // older event can never mix in.
            let analyzer = SNAudioStreamAnalyzer(format: format)
            let observer = Observer(owner: self)
            try analyzer.add(request, withObserver: observer)
            self.analyzer = analyzer
            self.observer = observer
            position = 0
            pending = nil
            active = true
        } catch {
            fail("\(error.localizedDescription)")
        }
    }

    private func stop() {
        guard active else { return }
        active = false
        // No completeAnalysis(): it would give one more verdict for a half window after the end.
        analyzer?.removeAllRequests()
        analyzer = nil
        observer = nil
        pending = nil
    }

    private func makeRequest() throws -> SNClassifySoundRequest {
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = Self.window(CMTime(seconds: 1, preferredTimescale: 8000),
                                             within: request.windowDurationConstraint)
        request.overlapFactor = 0.5
        Log.shared.add(String(format: "cry classifier loaded, window %.2f s", request.windowDuration.seconds))
        return request
    }

    /// The wanted window, or the nearest one that the classifier allows. A window it does not
    /// allow would make the request fail.
    private static func window(_ wanted: CMTime, within constraint: SNTimeDurationConstraint) -> CMTime {
        switch constraint.type {
        case .range:
            return CMTimeClampToRange(wanted, range: constraint.durationRange)
        case .enumerated:
            let options = constraint.enumeratedDurations.map(\.timeValue)
            return options.min { abs(($0 - wanted).seconds) < abs(($1 - wanted).seconds) } ?? wanted
        @unknown default:
            return wanted
        }
    }

    private func append(_ samples: [Float]) {
        guard active, let analyzer else { return }
        var i = 0
        while i < samples.count {
            if pending == nil {
                pending = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)
                pending?.frameLength = 0
            }
            guard let buffer = pending, let out = buffer.floatChannelData?[0] else { return }
            let filled = Int(buffer.frameLength)
            let n = min(Int(chunk) - filled, samples.count - i)
            for j in 0..<n { out[filled + j] = samples[i + j] }
            buffer.frameLength = AVAudioFrameCount(filled + n)
            i += n
            if buffer.frameLength == chunk {
                // A new buffer each time: the analyzer may still read this one.
                analyzer.analyze(buffer, atAudioFramePosition: position)
                position += AVAudioFramePosition(chunk)
                pending = nil
            }
        }
    }

    private func fail(_ why: String) {
        guard !broken else { return }
        broken = true
        stop()
        request = nil
        failureSink?(why)
    }

    // MARK: The results, on the analyzer's thread

    fileprivate func produced(_ result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let verdict = Self.verdict(result.classifications.map { ($0.identifier, Float($0.confidence)) })
        switch verdict {
        case .cry(let c):
            let label = result.classifications.first?.identifier == Self.cryingSobbing ? Self.cryingSobbing : Self.babyCrying
            Log.shared.add(String(format: "cry: %@ %.2f", label, c))
        case .other(let label, let c):
            Log.shared.add(String(format: "cry: other %@ %.2f", label, c))
        }
        q.async { if self.active { self.verdictSink?(verdict) } }
    }

    fileprivate func analyzerFailed(_ error: Error) {
        let why = error.localizedDescription
        q.async { self.fail(why) }
    }
}

/// The analyzer's observer. It keeps no state of its own.
private final class Observer: NSObject, SNResultsObserving, @unchecked Sendable {
    private weak var owner: CryDetector?

    init(owner: CryDetector) { self.owner = owner }

    func request(_ request: SNRequest, didProduce result: SNResult) { owner?.produced(result) }
    func request(_ request: SNRequest, didFailWithError error: Error) { owner?.analyzerFailed(error) }
    func requestDidComplete(_ request: SNRequest) {}
}
