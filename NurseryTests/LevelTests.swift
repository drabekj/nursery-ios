import XCTest
@testable import Nursery

/// The level of the room: RMS to 0...1 on a dB scale, -58 dBFS to -12 dBFS.
final class LevelTests: XCTestCase {
    private func rms(dB: Float) -> Float { powf(10, dB / 20) }

    func testSilenceIsZero() {
        XCTAssertEqual(LiveAudioPlayer.level(fromRMS: 0), 0)
        XCTAssertEqual(LiveAudioPlayer.level(fromRMS: rms(dB: -80)), 0)
        XCTAssertEqual(LiveAudioPlayer.level(fromRMS: rms(dB: -58)), 0, accuracy: 0.001)
    }

    func testLoudIsClampedToOne() {
        XCTAssertEqual(LiveAudioPlayer.level(fromRMS: rms(dB: -12)), 1, accuracy: 0.001)
        XCTAssertEqual(LiveAudioPlayer.level(fromRMS: rms(dB: -6)), 1)
        XCTAssertEqual(LiveAudioPlayer.level(fromRMS: 1), 1)
        XCTAssertEqual(LiveAudioPlayer.level(fromRMS: 4), 1)
    }

    func testMiddle() {
        XCTAssertEqual(LiveAudioPlayer.level(fromRMS: rms(dB: -35)), 0.5, accuracy: 0.001)
    }

    func testMonotonic() {
        var last: Float = 0
        for step in 0...200 {
            let level = LiveAudioPlayer.level(fromRMS: Float(step) / 200)
            XCTAssertGreaterThanOrEqual(level, last)
            XCTAssertTrue((0...1).contains(level))
            last = level
        }
    }
}
