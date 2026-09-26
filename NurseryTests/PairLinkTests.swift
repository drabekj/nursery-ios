import XCTest
@testable import Nursery

/// The link in the QR code of the phone at the baby. The Android app reads and makes the same.
final class PairLinkTests: XCTestCase {
    func testParsesTheLink() throws {
        let url = try XCTUnwrap(URL(string: "chuvicka://pair?n=Pokoj%C3%AD%C4%8Dek&c=482913&a=100.101.102.103:8555,192.168.0.42:8555"))
        let link = try XCTUnwrap(PairLink(url: url))
        XCTAssertEqual(link.name, "Pokojíček")
        XCTAssertEqual(link.code, "482913")
        XCTAssertEqual(link.addresses, ["100.101.102.103:8555", "192.168.0.42:8555"])
    }

    func testNoAddressesIsFine() throws {
        let url = try XCTUnwrap(URL(string: "chuvicka://pair?n=Pokoj&c=482913"))
        let link = try XCTUnwrap(PairLink(url: url))
        XCTAssertEqual(link.addresses, [])
    }

    func testRejectsBadLinks() {
        let bad = [
            "https://pair?n=Pokoj&c=482913",           // Another scheme
            "chuvicka://pairing?n=Pokoj&c=482913",     // Another host
            "chuvicka://pair?c=482913",                // No name
            "chuvicka://pair?n=&c=482913",             // An empty name
            "chuvicka://pair?n=Pokoj",                 // No code
            "chuvicka://pair?n=Pokoj&c=48291",         // 5 digits
            "chuvicka://pair?n=Pokoj&c=4829130",       // 7 digits
            "chuvicka://pair",                         // Nothing
        ]
        for text in bad {
            guard let url = URL(string: text) else { XCTFail("not a URL: \(text)"); continue }
            XCTAssertNil(PairLink(url: url), text)
        }
    }

    func testRoundTrip() {
        let link = PairLink(name: "Dětský pokojíček", code: "007315",
                            addresses: ["100.64.0.7:8555", "192.168.0.42:8555"])
        XCTAssertEqual(link.url.scheme, "chuvicka")
        XCTAssertEqual(link.url.host, "pair")
        XCTAssertEqual(PairLink(url: link.url), link)
    }

    func testRoundTripWithNoAddresses() {
        let link = PairLink(name: "Ložnice", code: "123456", addresses: [])
        XCTAssertEqual(PairLink(url: link.url), link)
    }
}
