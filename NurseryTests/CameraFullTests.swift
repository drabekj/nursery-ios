import XCTest
@testable import Nursery

/// A direct camera serves only a few sessions. One more is refused: RTSP 453, or a close before PLAY.
final class CameraFullTests: XCTestCase {
    func testStatus453() {
        XCTAssertTrue(RTSPClient.isCameraFull(status: 453, closedBeforePlay: false, directCamera: true))
    }

    func testCloseBeforePlay() {
        XCTAssertTrue(RTSPClient.isCameraFull(status: nil, closedBeforePlay: true, directCamera: true))
    }

    // go2rtc and the phone at the baby are never "full".
    func testNotDirectCamera() {
        XCTAssertFalse(RTSPClient.isCameraFull(status: nil, closedBeforePlay: true, directCamera: false))
        XCTAssertFalse(RTSPClient.isCameraFull(status: 453, closedBeforePlay: false, directCamera: false))
    }

    // A wrong password stays a login error.
    func testLoginErrorIsNotFull() {
        XCTAssertFalse(RTSPClient.isCameraFull(status: 401, closedBeforePlay: false, directCamera: true))
    }

    func testOtherEndIsNotFull() {
        XCTAssertFalse(RTSPClient.isCameraFull(status: nil, closedBeforePlay: false, directCamera: true))
    }

    func testMessage() {
        XCTAssertEqual(RTSPClient.Failure.cameraFull.errorDescription,
                       "Kameru teď sleduje příliš mnoho telefonů. Zkuste to za chvíli, nebo zavřete Chůvičku na jiném telefonu.")
    }
}
