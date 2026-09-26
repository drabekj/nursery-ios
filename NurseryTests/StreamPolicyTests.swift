import XCTest
@testable import Nursery

/// The automatic picture quality: the detail stream only where it shows and the phone can afford it.
final class StreamPolicyTests: XCTestCase {
    /// Everything allows the detail stream.
    private let allowed = StreamPolicy.Inputs(wantsDetail: true, soundOnly: false, thermalHot: false, lowPower: false,
                                              detailStream: "nursery", everydayStream: "nursery_sd")

    func testDetailWhenEverythingAllows() {
        XCTAssertTrue(StreamPolicy.detail(allowed))
        XCTAssertEqual(StreamPolicy.stream(allowed), "nursery")
    }

    func testEachInputFlipsTheResult() {
        var i = allowed
        i.wantsDetail = false
        XCTAssertFalse(StreamPolicy.detail(i))
        XCTAssertEqual(StreamPolicy.stream(i), "nursery_sd")

        i = allowed
        i.soundOnly = true
        XCTAssertFalse(StreamPolicy.detail(i))

        i = allowed
        i.thermalHot = true
        XCTAssertFalse(StreamPolicy.detail(i))

        i = allowed
        i.lowPower = true
        XCTAssertFalse(StreamPolicy.detail(i))
        XCTAssertEqual(StreamPolicy.stream(i), "nursery_sd")
    }

    // One stream only (the phone at the baby, "Jiná kamera", or go2rtc with one stream).
    func testEqualStreamsNeverGiveDetail() {
        var i = allowed
        i.everydayStream = i.detailStream
        XCTAssertFalse(StreamPolicy.detail(i))
        XCTAssertEqual(StreamPolicy.stream(i), "nursery")
        i.detailStream = ""
        i.everydayStream = ""
        XCTAssertFalse(StreamPolicy.detail(i))
    }
}
