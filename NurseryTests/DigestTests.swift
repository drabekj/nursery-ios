import CryptoKit
import XCTest
@testable import Nursery

/// The camera login: RFC 2617 Digest, and the WWW-Authenticate parser.
final class DigestTests: XCTestCase {
    private func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // The example of RFC 2617, section 3.5.
    func testRFC2617Example() {
        let header = RTSPClient.digestHeader(user: "Mufasa", password: "Circle Of Life", method: "GET",
                                             uri: "/dir/index.html", realm: "testrealm@host.com",
                                             nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093", qop: true,
                                             opaque: "5ccc069c403ebaf9f0171e9517f40e41",
                                             nc: 1, cnonce: "0a4f113b")
        XCTAssertTrue(header.hasPrefix("Digest "))
        // The header has the same form as a challenge, so the parser reads it back.
        let fields = RTSPClient.parseChallenge(header)
        XCTAssertEqual(fields["username"], "Mufasa")
        XCTAssertEqual(fields["realm"], "testrealm@host.com")
        XCTAssertEqual(fields["nonce"], "dcd98b7102dd2f0e8b11d0f600bfb0c093")
        XCTAssertEqual(fields["uri"], "/dir/index.html")
        XCTAssertEqual(fields["qop"], "auth")
        XCTAssertEqual(fields["nc"], "00000001")
        XCTAssertEqual(fields["cnonce"], "0a4f113b")
        XCTAssertEqual(fields["response"], "6629fae49393a05397450978507c4ef1")
        XCTAssertEqual(fields["opaque"], "5ccc069c403ebaf9f0171e9517f40e41")
    }

    // With no qop (RFC 2069): response = MD5(HA1:nonce:HA2), and no nc or cnonce.
    func testNoQop() {
        let header = RTSPClient.digestHeader(user: "admin", password: "tajne heslo", method: "DESCRIBE",
                                             uri: "rtsp://192.168.0.20:554/stream1", realm: "IP Camera",
                                             nonce: "a1b2c3", qop: false, opaque: nil,
                                             nc: 0, cnonce: "")
        let ha1 = md5("admin:IP Camera:tajne heslo")
        let ha2 = md5("DESCRIBE:rtsp://192.168.0.20:554/stream1")
        let fields = RTSPClient.parseChallenge(header)
        XCTAssertEqual(fields["response"], md5("\(ha1):a1b2c3:\(ha2)"))
        XCTAssertNil(fields["qop"])
        XCTAssertNil(fields["nc"])
        XCTAssertNil(fields["cnonce"])
        XCTAssertNil(fields["opaque"])
    }

    func testNonceCountIsEightHexDigits() {
        let header = RTSPClient.digestHeader(user: "u", password: "p", method: "PLAY", uri: "rtsp://h/s",
                                             realm: "r", nonce: "n", qop: true, opaque: nil,
                                             nc: 26, cnonce: "c")
        XCTAssertEqual(RTSPClient.parseChallenge(header)["nc"], "0000001a")
    }

    func testParseQuotedChallenge() {
        let fields = RTSPClient.parseChallenge(
            #"Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41""#)
        XCTAssertEqual(fields["scheme"], "digest")
        XCTAssertEqual(fields["realm"], "testrealm@host.com")
        XCTAssertEqual(fields["qop"], "auth,auth-int")      // The comma inside the quotes stays.
        XCTAssertEqual(fields["nonce"], "dcd98b7102dd2f0e8b11d0f600bfb0c093")
        XCTAssertEqual(fields["opaque"], "5ccc069c403ebaf9f0171e9517f40e41")
    }

    func testParseUnquotedChallenge() {
        let fields = RTSPClient.parseChallenge("Digest Realm=cam, nonce=YWJj==, stale=FALSE")
        XCTAssertEqual(fields["scheme"], "digest")
        XCTAssertEqual(fields["realm"], "cam")               // The keys are lower case.
        XCTAssertEqual(fields["nonce"], "YWJj==")            // Split at the first "=" only.
        XCTAssertEqual(fields["stale"], "FALSE")
    }

    // A quoted value with spaces, a comma and "=": one value, no extra fields.
    func testParseQuotedValueWithCommaAndEquals() {
        let fields = RTSPClient.parseChallenge(#"Digest realm="Pokoj, a=b", nonce="n1""#)
        XCTAssertEqual(fields["realm"], "Pokoj, a=b")
        XCTAssertNil(fields["a"])
        XCTAssertEqual(fields["nonce"], "n1")
    }

    func testParseBasic() {
        let fields = RTSPClient.parseChallenge(#"Basic realm="Tapo""#)
        XCTAssertEqual(fields["scheme"], "basic")
        XCTAssertEqual(fields["realm"], "Tapo")
    }
}
