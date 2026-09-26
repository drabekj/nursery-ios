import AVFoundation
import os
import SoundAnalysis
import XCTest
@testable import Nursery

/// The cry classifier: the identifiers it knows, the verdict rule, and the whole path at 8000 Hz.
final class CryDetectorTests: XCTestCase {
    func testClassifierKnowsBabyCrying() throws {
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        let known = request.knownClassifications
        // For the CI log: the exact names of the crying sounds, and the windows the classifier allows.
        print("CRY: \(known.count) classifications; with 'cry': \(known.filter { $0.contains("cry") }.prefix(20))")
        print("CRY: with 'sob': \(known.filter { $0.contains("sob") }.prefix(20))")
        let c = request.windowDurationConstraint
        switch c.type {
        case .range: print("CRY: window range \(c.durationRange.start.seconds)...\(c.durationRange.end.seconds) s")
        case .enumerated: print("CRY: windows \(c.enumeratedDurations.map { $0.timeValue.seconds }) s")
        @unknown default: print("CRY: window constraint unknown")
        }
        XCTAssertTrue(known.contains(CryDetector.babyCrying))
        XCTAssertTrue(known.contains(CryDetector.cryingSobbing), "crying_sobbing is not known; the detector then ignores it")
    }

    func testTopBabyCryingIsCry() {
        XCTAssertEqual(CryDetector.verdict([("speech", 0.2), ("baby_crying", 0.82)]), .cry(0.82))
    }

    func testBabyCryingUnderSpeechCountsWhenSure() {
        XCTAssertEqual(CryDetector.verdict([("speech", 0.7), ("baby_crying", 0.55)]), .cry(0.55))
        XCTAssertEqual(CryDetector.verdict([("speech", 0.7), ("baby_crying", 0.4)]), .other("speech", 0.7))
    }

    func testSobbingNeedsSixty() {
        XCTAssertEqual(CryDetector.verdict([("crying_sobbing", 0.65), ("speech", 0.3)]), .cry(0.65))
        XCTAssertEqual(CryDetector.verdict([("crying_sobbing", 0.55), ("speech", 0.3)]), .other("crying_sobbing", 0.55))
    }

    func testOtherAndNothing() {
        XCTAssertEqual(CryDetector.verdict([("dog", 0.9), ("speech", 0.1)]), .other("dog", 0.9))
        XCTAssertEqual(CryDetector.verdict([]), .other("nothing", 0))
    }

    /// The analyzer gets 8000 Hz sound, half the model's rate. It must still give verdicts (or
    /// fail cleanly, and then the engine uses the loudness rule). The log says which.
    func testVerdictsAt8kHz() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false)!
        let detector = CryDetector(format: format)
        let outcome = OSAllocatedUnfairLock<String?>(initialState: nil)
        let done = expectation(description: "a verdict or a failure")
        done.assertForOverFulfill = false
        detector.setSinks(verdict: { v in
            outcome.withLock { if $0 == nil { $0 = "verdict \(v)" } }
            done.fulfill()
        }, failure: { why in
            outcome.withLock { if $0 == nil { $0 = "failure \(why)" } }
            done.fulfill()
        })
        detector.setActive(true)
        // 3 s of a wobbling tone with noise, in RTP-sized packets of 20 ms.
        var t = 0
        for _ in 0..<150 {
            var packet = [Float](repeating: 0, count: 160)
            for i in 0..<160 {
                let x = Double(t) / 8000
                let f = 450 + 80 * sin(6 * Double.pi * x)
                let v = 0.4 * sin(2 * Double.pi * f * x)
                packet[i] = Float(v) + Float.random(in: -0.05...0.05)
                t += 1
            }
            detector.feed(packet)
        }
        wait(for: [done], timeout: 20)
        let result = outcome.withLock { $0 } ?? "nothing"
        print("CRY: 8 kHz outcome: \(result)")
        // A failure is a correct outcome too (the engine then uses the loudness rule), but the
        // log line above must then be read: it means no classifier on the phones.
        XCTAssertNotEqual(result, "nothing", "no verdict and no failure in 20 s")
        detector.setActive(false)
    }
}
