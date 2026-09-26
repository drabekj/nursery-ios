import XCTest
@testable import Nursery

/// ONVIF pan and tilt: the WS-Security digest, the SOAP bodies, and the profile token.
final class ONVIFTests: XCTestCase {
    private let nonce = Array("0123456789abcdef".utf8)

    // The shared vector: Android asserts the same values.
    func testSecurityHeaderVector() {
        let header = ONVIF.securityHeader(user: "admin", password: "secret", nonce: nonce, created: "2026-09-26T20:00:00Z")
        XCTAssertTrue(header.contains("<wsse:Nonce>MDEyMzQ1Njc4OWFiY2RlZg==</wsse:Nonce>"))
        XCTAssertTrue(header.contains("#PasswordDigest\">hM5GeUSvJCyVdAjYUQilpGW5Hhw=</wsse:Password>"))
        XCTAssertTrue(header.contains("<wsu:Created>2026-09-26T20:00:00Z</wsu:Created>"))
        XCTAssertTrue(header.contains("<wsse:Username>admin</wsse:Username>"))
        XCTAssertFalse(header.contains("secret"))            // Only the digest leaves the phone.
    }

    func testEnvelopeHoldsHeaderAndBody() {
        let security = ONVIF.securityHeader(user: "u", password: "p", nonce: nonce, created: "2026-09-26T20:00:00Z")
        let envelope = ONVIF.envelope(body: ONVIF.getProfilesBody, security: security)
        XCTAssertTrue(envelope.hasPrefix("<?xml"))
        XCTAssertTrue(envelope.contains("<s:Header>" + security + "</s:Header>"))
        XCTAssertTrue(envelope.contains("<s:Body>" + ONVIF.getProfilesBody + "</s:Body>"))
        XCTAssertTrue(envelope.hasSuffix("</s:Envelope>"))
    }

    func testContinuousMoveBody() {
        let body = ONVIF.continuousMoveBody(token: "profile_1", x: -0.5, y: 0)
        XCTAssertTrue(body.contains(#"x="-0.5" y="0.0""#))
        XCTAssertTrue(body.contains("<tptz:ProfileToken>profile_1</tptz:ProfileToken>"))
        XCTAssertTrue(ONVIF.continuousMoveBody(token: "t", x: 0, y: 0.5).contains(#"x="0.0" y="0.5""#))
    }

    func testStopBody() {
        let body = ONVIF.stopBody(token: "profile_1")
        XCTAssertTrue(body.contains("<tptz:PanTilt>true</tptz:PanTilt>"))
        XCTAssertTrue(body.contains("<tptz:ProfileToken>profile_1</tptz:ProfileToken>"))
    }

    private let ptzProfile = #"<trt:Profiles fixed="true" token="profile_1"><tt:Name>mainStream</tt:Name><tt:PTZConfiguration token="ptz_conf"><tt:Name>PTZ</tt:Name></tt:PTZConfiguration></trt:Profiles>"#
    private let plainProfile = #"<trt:Profiles fixed="true" token="profile_2"><tt:Name>minorStream</tt:Name><tt:VideoEncoderConfiguration token="enc"/></trt:Profiles>"#

    private func response(_ profiles: String) -> String {
        #"<?xml version="1.0"?><SOAP-ENV:Envelope><SOAP-ENV:Body><trt:GetProfilesResponse>"#
            + profiles + "</trt:GetProfilesResponse></SOAP-ENV:Body></SOAP-ENV:Envelope>"
    }

    func testTokenOfFirstPTZProfile() {
        XCTAssertEqual(ONVIF.ptzProfileToken(in: response(ptzProfile + plainProfile)), "profile_1")
    }

    func testNoPTZProfile() {
        XCTAssertNil(ONVIF.ptzProfileToken(in: response(plainProfile)))
        XCTAssertNil(ONVIF.ptzProfileToken(in: "<html>Not found</html>"))
    }

    func testPTZProfileSecond() {
        let plainFirst = plainProfile.replacingOccurrences(of: "profile_2", with: "profile_0")
        let second = ptzProfile.replacingOccurrences(of: "profile_1", with: "profile_9")
        XCTAssertEqual(ONVIF.ptzProfileToken(in: response(plainFirst + second)), "profile_9")
    }

    func testOtherPrefixAndLineBreaks() {
        let xml = "<ns2:GetProfilesResponse>\n<ns2:Profiles\n  token=\"main\" fixed=\"true\">\n<ns1:PTZConfiguration token=\"p\">\n</ns1:PTZConfiguration>\n</ns2:Profiles>\n</ns2:GetProfilesResponse>"
        XCTAssertEqual(ONVIF.ptzProfileToken(in: xml), "main")
    }

    func testCreatedFormat() {
        let created = ONVIF.createdNow()
        XCTAssertEqual(created.count, 20)
        XCTAssertTrue(created.hasSuffix("Z"))
        XCTAssertNotNil(created.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#, options: .regularExpression))
    }
}
