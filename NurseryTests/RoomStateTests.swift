import XCTest
@testable import Nursery

/// The word on the screen, from the signals: Připojuji, Klid, Ozývá se, Pláče, Nehlídá.
final class RoomStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func input(heard: Bool = true, everHeard: Bool = true, event: Bool = false, seconds: TimeInterval = 0,
                       peak: Float = 0, level: Float = 0, classifier: Bool = true) -> RoomStateMachine.Input {
        .init(heard: heard, everHeard: everHeard, eventRunning: event, eventSeconds: seconds, eventPeak: peak,
              level: level, classifierAvailable: classifier)
    }

    func testStartsConnectingThenCalm() {
        var m = RoomStateMachine()
        XCTAssertEqual(m.update(input(heard: false, everHeard: false), now: at(0)), .connecting)
        XCTAssertEqual(m.update(input(heard: false, everHeard: false), now: at(19)), .connecting)
        XCTAssertEqual(m.update(input(), now: at(20)), .calm)
        XCTAssertEqual(m.since, at(20))
    }

    func testNeverHeardBecomesLostAfter20s() {
        var m = RoomStateMachine()
        m.update(input(heard: false, everHeard: false), now: at(0))
        XCTAssertEqual(m.update(input(heard: false, everHeard: true), now: at(5)), .connecting)
        XCTAssertEqual(m.update(input(heard: false, everHeard: true), now: at(24)), .connecting)
        XCTAssertEqual(m.update(input(heard: false, everHeard: true), now: at(25)), .lost)
    }

    func testGapKeepsTheLastStateThenLost() {
        var m = RoomStateMachine()
        m.update(input(), now: at(0))
        XCTAssertEqual(m.update(input(heard: false), now: at(1)), .calm)
        XCTAssertEqual(m.update(input(heard: false), now: at(20)), .calm)
        XCTAssertEqual(m.update(input(heard: false), now: at(21)), .lost)
        XCTAssertEqual(m.update(input(), now: at(22)), .calm)
    }

    func testSoundWithoutCryVerdicts() {
        var m = RoomStateMachine()
        m.update(input(), now: at(0))
        XCTAssertEqual(m.update(input(event: true), now: at(1)), .sound)
        m.classified(.other("dog", 0.8))
        m.classified(.cry(0.3))
        m.classified(.other("speech", 0.6))
        XCTAssertEqual(m.update(input(event: true), now: at(2)), .sound)
    }

    func testTwoOfThreeCryVerdictsGiveCry() {
        var m = RoomStateMachine()
        m.update(input(), now: at(0))
        m.update(input(event: true), now: at(1))
        m.classified(.cry(0.9))
        XCTAssertEqual(m.update(input(event: true), now: at(1.5)), .sound)
        m.classified(.other("speech", 0.5))
        m.classified(.cry(0.6))
        XCTAssertEqual(m.update(input(event: true), now: at(2)), .cry)
        XCTAssertEqual(m.since, at(2))
    }

    func testCryHoldsThroughAPauseAndEndsWithTheEvent() {
        var m = RoomStateMachine()
        m.update(input(), now: at(0))
        m.update(input(event: true), now: at(1))
        m.classified(.cry(0.9)); m.classified(.cry(0.9))
        XCTAssertEqual(m.update(input(event: true), now: at(2)), .cry)
        // The baby breathes: three "other" verdicts. Still Pláče for 15 s.
        m.classified(.other("silence", 0.9)); m.classified(.other("silence", 0.9)); m.classified(.other("silence", 0.9))
        XCTAssertEqual(m.update(input(event: true), now: at(10)), .cry)
        XCTAssertEqual(m.update(input(event: true), now: at(16.5)), .cry)   // The 15 s hold from 2 s runs to 17 s.
        XCTAssertEqual(m.update(input(event: true), now: at(17.5)), .sound)
        XCTAssertEqual(m.update(input(event: false), now: at(18)), .calm)
    }

    func testCryEndsTenSecondsAfterTheLastVerdict() {
        var m = RoomStateMachine()
        m.update(input(), now: at(0))
        m.update(input(event: true), now: at(1))
        m.classified(.cry(0.9)); m.classified(.cry(0.9))
        m.update(input(event: true), now: at(2))
        m.classified(.cry(0.9))
        m.update(input(event: true), now: at(20))          // A cry verdict again at 20 s.
        m.classified(.other("x", 1)); m.classified(.other("x", 1)); m.classified(.other("x", 1))
        XCTAssertEqual(m.update(input(event: true), now: at(29)), .cry)
        XCTAssertEqual(m.update(input(event: true), now: at(30.5)), .sound)
    }

    func testEventEndClearsVerdicts() {
        var m = RoomStateMachine()
        m.update(input(), now: at(0))
        m.update(input(event: true), now: at(1))
        m.classified(.cry(0.9)); m.classified(.cry(0.9))
        m.update(input(event: true), now: at(2))
        XCTAssertEqual(m.update(input(event: false), now: at(30)), .calm)
        XCTAssertTrue(m.verdicts.isEmpty)
        XCTAssertEqual(m.update(input(event: true), now: at(40)), .sound)
    }

    func testLoudnessRuleWithoutClassifier() {
        var m = RoomStateMachine()
        m.update(input(classifier: false), now: at(0))
        // Loud ticks at 2 Hz: 12 ticks = 6 s of loud sound within 12 s.
        var state: RoomState = .calm
        for i in 0..<12 {
            state = m.update(input(event: true, seconds: Double(i) / 2, level: 0.7, classifier: false), now: at(1 + Double(i) / 2))
        }
        XCTAssertEqual(state, .cry)
        // A quieter loud spell does not count.
        var q = RoomStateMachine()
        q.update(input(classifier: false), now: at(0))
        for i in 0..<12 {
            state = q.update(input(event: true, seconds: Double(i) / 2, level: 0.3, classifier: false), now: at(1 + Double(i) / 2))
        }
        XCTAssertEqual(state, .sound)
    }

    func testLongLoudEventWithoutClassifier() {
        var m = RoomStateMachine()
        m.update(input(classifier: false), now: at(0))
        XCTAssertEqual(m.update(input(event: true, seconds: 11, peak: 0.9, level: 0.2, classifier: false), now: at(12)), .sound)
        XCTAssertEqual(m.update(input(event: true, seconds: 12, peak: 0.9, level: 0.2, classifier: false), now: at(13)), .cry)
    }

    func testClassifierVerdictsIgnoreLoudnessRule() {
        var m = RoomStateMachine()
        m.update(input(), now: at(0))
        // Loud and long, but the classifier says vacuum cleaner: Ozývá se, not Pláče.
        var state: RoomState = .calm
        for i in 0..<30 {
            m.classified(.other("vacuum_cleaner", 0.9))
            state = m.update(input(event: true, seconds: Double(i) / 2, peak: 0.95, level: 0.9), now: at(1 + Double(i) / 2))
        }
        XCTAssertEqual(state, .sound)
    }

    func testTitles() {
        XCTAssertEqual(RoomState.connecting.title, "Připojuji…")
        XCTAssertEqual(RoomState.calm.title, "Klid")
        XCTAssertEqual(RoomState.sound.title, "Ozývá se")
        XCTAssertEqual(RoomState.cry.title, "Pláče")
        XCTAssertEqual(RoomState.lost.title, "Nehlídá")
    }
}
