import XCTest
@testable import Nursery

/// G.711 against a second implementation, written from the ITU-T formulas
/// (the middle of each quantization step), not from g711.c.
final class G711Tests: XCTestCase {
    /// A-law: the even bits are inverted (0x55). Bit 7 set is positive.
    /// Segment 0: 2m + 1; segment e >= 1: (2m + 33) << (e - 1). In 13-bit steps, so << 3 for 16 bits.
    private func referenceALaw(_ code: UInt8) -> Int {
        let a = Int(code ^ 0x55)
        let e = (a >> 4) & 0x07, m = a & 0x0F
        let magnitude = e == 0 ? 2 * m + 1 : (2 * m + 33) << (e - 1)
        return (a & 0x80 != 0 ? 1 : -1) * (magnitude << 3)
    }

    /// μ-law: all the bits are inverted. Bit 7 set is negative.
    /// ((2m + 33) << e) - 33, in 14-bit steps, so << 2 for 16 bits.
    private func referenceULaw(_ code: UInt8) -> Int {
        let u = Int(~code)
        let e = (u >> 4) & 0x07, m = u & 0x0F
        let magnitude = ((2 * m + 33) << e) - 33
        return (u & 0x80 != 0 ? -1 : 1) * (magnitude << 2)
    }

    func testALawKnownValues() {
        XCTAssertEqual(G711.decodeALaw(0x55), -8)       // The smallest negative step
        XCTAssertEqual(G711.decodeALaw(0xD5), 8)
        XCTAssertEqual(G711.decodeALaw(0xAA), 32256)    // The largest
        XCTAssertEqual(G711.decodeALaw(0x2A), -32256)
    }

    func testULawKnownValues() {
        XCTAssertEqual(G711.decodeULaw(0xFF), 0)
        XCTAssertEqual(G711.decodeULaw(0x7F), 0)
        XCTAssertEqual(G711.decodeULaw(0x80), 32124)    // The largest
        XCTAssertEqual(G711.decodeULaw(0x00), -32124)
    }

    func testALawAllCodes() {
        for code in 0...255 {
            let c = UInt8(code)
            XCTAssertEqual(Int(G711.decodeALaw(c)), referenceALaw(c), "A-law code \(code)")
            XCTAssertEqual(G711.aLaw[code], G711.decodeALaw(c))
        }
    }

    func testULawAllCodes() {
        for code in 0...255 {
            let c = UInt8(code)
            XCTAssertEqual(Int(G711.decodeULaw(c)), referenceULaw(c), "μ-law code \(code)")
            XCTAssertEqual(G711.uLaw[code], G711.decodeULaw(c))
        }
    }

    // The phone at the baby encodes, the parent decodes: each code comes back.
    func testALawRoundTrip() {
        for code in 0...255 {
            let c = UInt8(code)
            XCTAssertEqual(G711.encodeALaw(G711.decodeALaw(c)), c, "A-law code \(code)")
        }
    }

    func testALawEncodeClampsAndKeepsTheSign() {
        XCTAssertEqual(G711.encodeALaw(Int16.max), 0xAA)
        XCTAssertEqual(G711.encodeALaw(Int16.min), 0x2A)
        XCTAssertEqual(G711.encodeALaw(0), 0xD5)
        XCTAssertEqual(G711.encodeALaw(-1), 0x55)
        // Louder in, larger out, on the positive side.
        var last = G711.decodeALaw(G711.encodeALaw(0))
        for pcm in stride(from: 0, through: Int(Int16.max), by: 97) {
            let back = G711.decodeALaw(G711.encodeALaw(Int16(pcm)))
            XCTAssertGreaterThanOrEqual(back, last)
            last = back
        }
    }
}
