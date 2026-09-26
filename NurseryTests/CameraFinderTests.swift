import XCTest
@testable import Nursery

/// The camera search: which addresses are home, and what a camera's answer says about it.
final class CameraFinderTests: XCTestCase {
    func testPrivateAddresses() {
        XCTAssertTrue(CameraFinder.isPrivate("192.168.0.12"))
        XCTAssertTrue(CameraFinder.isPrivate("10.0.0.5"))
        XCTAssertTrue(CameraFinder.isPrivate("172.20.1.1"))
        XCTAssertFalse(CameraFinder.isPrivate("172.32.1.1"))
        XCTAssertFalse(CameraFinder.isPrivate("100.104.188.72"))      // Tailscale.
        XCTAssertFalse(CameraFinder.isPrivate("8.8.8.8"))
    }

    func testBrandFromRealm() {
        let tapo = "RTSP/1.0 401 Unauthorized\r\nCSeq: 1\r\nWWW-Authenticate: Digest realm=\"TP-LINK IP-Camera\", nonce=\"abc\"\r\n\r\n"
        XCTAssertEqual(CameraFinder.brand(in: tapo), .tapo)
        XCTAssertEqual(CameraFinder.label(in: tapo), "Tapo (TP-Link)")
        let dahua = "RTSP/1.0 401 Unauthorized\r\nWWW-Authenticate: Digest realm=\"Login to 4K0123PAZ\", nonce=\"x\"\r\n\r\n"
        XCTAssertEqual(CameraFinder.brand(in: dahua), .dahua)
    }

    func testUnknownDeviceKeepsItsName() {
        let other = "RTSP/1.0 404 Not Found\r\nCSeq: 1\r\nServer: Rtsp Server 3.0\r\n\r\n"
        XCTAssertNil(CameraFinder.brand(in: other))
        XCTAssertEqual(CameraFinder.label(in: other), "Rtsp Server 3.0")
        XCTAssertNil(CameraFinder.label(in: "RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n"))
    }
}
