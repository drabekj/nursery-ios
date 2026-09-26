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

    // MARK: Which interface is home

    func testWiFiWinsOverHotspot() {
        let net = CameraFinder.pick([(name: "bridge100", ip: "172.20.10.1"), (name: "en0", ip: "192.168.0.12")])
        XCTAssertEqual(net?.own, "192.168.0.12")
        XCTAssertEqual(net?.prefix, "192.168.0")
    }

    func testHotspotWinsOverMobileData() {
        let net = CameraFinder.pick([(name: "pdp_ip0", ip: "10.64.3.7"), (name: "bridge100", ip: "172.20.10.1")])
        XCTAssertEqual(net?.own, "172.20.10.1")
        XCTAssertEqual(net?.prefix, "172.20.10")
    }

    func testOtherEthernetIsUsed() {
        let net = CameraFinder.pick([(name: "lo0", ip: "127.0.0.1"), (name: "en2", ip: "10.0.0.5")])
        XCTAssertEqual(net?.own, "10.0.0.5")
        XCTAssertEqual(net?.prefix, "10.0.0")
    }

    func testMobileDataOnlyIsNoHome() {
        XCTAssertNil(CameraFinder.pick([(name: "pdp_ip0", ip: "10.64.3.7")]))
    }

    func testTailscaleIsIgnored() {
        XCTAssertNil(CameraFinder.pick([(name: "utun4", ip: "100.100.1.1")]))
        let net = CameraFinder.pick([(name: "utun4", ip: "100.100.1.1"), (name: "en0", ip: "192.168.1.20")])
        XCTAssertEqual(net?.own, "192.168.1.20")
    }

    func testRelocateURLEncodesTheLogin() {
        XCTAssertEqual(CameraFinder.rtspURL(host: "192.168.0.50", port: 554, path: "stream1", user: "u@x", password: "p:ss"),
                       "rtsp://u%40x:p%3Ass@192.168.0.50:554/stream1")
        XCTAssertEqual(CameraFinder.rtspURL(host: "192.168.0.50", port: 554, path: "stream1", user: " ", password: "x"),
                       "rtsp://192.168.0.50:554/stream1")
    }
}
