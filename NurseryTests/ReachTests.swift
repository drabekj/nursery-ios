import XCTest
@testable import Nursery

/// The addresses for the time away from home.
final class ReachTests: XCTestCase {
    func testSplit() throws {
        let a = try XCTUnwrap(Reach.split("192.168.0.50:8555"))
        XCTAssertEqual(a.host, "192.168.0.50")
        XCTAssertEqual(a.port, 8555)
        let t = try XCTUnwrap(Reach.split("100.101.102.103:554"))
        XCTAssertEqual(t.host, "100.101.102.103")
        XCTAssertEqual(t.port, 554)
    }

    func testSplitRejectsABadPort() {
        XCTAssertNil(Reach.split("192.168.0.50"))          // No port
        XCTAssertNil(Reach.split("192.168.0.50:"))         // An empty port
        XCTAssertNil(Reach.split("192.168.0.50:abc"))
        XCTAssertNil(Reach.split("192.168.0.50:65536"))    // Above UInt16
        XCTAssertNil(Reach.split("192.168.0.50:-1"))
    }

    // The port is after the last ":".
    func testSplitUsesTheLastColon() throws {
        let a = try XCTUnwrap(Reach.split("[fe80::1]:8555"))
        XCTAssertEqual(a.host, "[fe80::1]")
        XCTAssertEqual(a.port, 8555)
    }

    // 100.64.0.0/10: the first octet 100, the second 64...127.
    func testIsTailscale() {
        XCTAssertTrue(Reach.isTailscale("100.64.0.1"))
        XCTAssertTrue(Reach.isTailscale("100.64.0.0"))
        XCTAssertTrue(Reach.isTailscale("100.101.102.103"))
        XCTAssertTrue(Reach.isTailscale("100.127.255.255"))
        XCTAssertFalse(Reach.isTailscale("100.63.255.255"))
        XCTAssertFalse(Reach.isTailscale("100.128.0.0"))
        XCTAssertFalse(Reach.isTailscale("192.168.0.1"))
        XCTAssertFalse(Reach.isTailscale("10.64.0.1"))
        XCTAssertFalse(Reach.isTailscale("100.64.0"))      // Not four parts
        XCTAssertFalse(Reach.isTailscale("pi.tail1234.ts.net"))
        XCTAssertFalse(Reach.isTailscale(""))
    }
}
