import XCTest
@testable import Nursery

/// One RTP packet with a plain 12-byte header, payload type 96.
private func rtp(seq: UInt16, ts: UInt32 = 3000, marker: Bool = true, _ payload: [UInt8]) -> RTPPacket {
    let m: UInt8 = marker ? 0x80 : 0
    var b: [UInt8] = [0x80, m | 96, UInt8(seq >> 8), UInt8(seq & 0xFF)]
    b += [UInt8(ts >> 24), UInt8((ts >> 16) & 0xFF), UInt8((ts >> 8) & 0xFF), UInt8(ts & 0xFF)]
    b += [0x11, 0x22, 0x33, 0x44]   // SSRC
    b += payload
    return RTPPacket(b)!            // The header is valid, so this never fails.
}

final class RTPPacketTests: XCTestCase {
    func testParsesTheHeader() throws {
        let b: [UInt8] = [0x80, 0xE0, 0x12, 0x34, 0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04, 0x65, 0x88]
        let p = try XCTUnwrap(RTPPacket(b))
        XCTAssertEqual(p.payloadType, 96)
        XCTAssertTrue(p.marker)
        XCTAssertEqual(p.sequence, 0x1234)
        XCTAssertEqual(p.timestamp, 0xDEAD_BEEF)
        XCTAssertEqual(Array(p.payload), [0x65, 0x88])
    }

    func testNoMarker() throws {
        let p = try XCTUnwrap(RTPPacket([0x80, 0x08, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0xD5]))
        XCTAssertEqual(p.payloadType, 8)
        XCTAssertFalse(p.marker)
        XCTAssertEqual(Array(p.payload), [0xD5])
    }

    // Two CSRCs, a header extension of one word, and 3 bytes of padding: only the payload is left.
    func testSkipsCSRCExtensionAndPadding() throws {
        var b: [UInt8] = [0x80 | 0x20 | 0x10 | 0x02, 0xE0, 0x00, 0x07, 0x00, 0x00, 0x0B, 0xB8, 0xAA, 0xBB, 0xCC, 0xDD]
        b += [0, 0, 0, 1, 0, 0, 0, 2]              // CSRC 1 and 2
        b += [0xBE, 0xDE, 0x00, 0x01, 9, 9, 9, 9]  // The extension: profile, length 1 word, the word
        b += [1, 2, 3]                              // The payload
        b += [0, 0, 3]                              // The padding. The last byte is its length.
        let p = try XCTUnwrap(RTPPacket(b))
        XCTAssertEqual(p.sequence, 7)
        XCTAssertEqual(p.timestamp, 3000)
        XCTAssertEqual(Array(p.payload), [1, 2, 3])
    }

    func testRejectsBadInput() {
        XCTAssertNil(RTPPacket([]))
        XCTAssertNil(RTPPacket([0x80, 0x60, 0, 1, 0, 0, 0, 0, 0, 0, 0]))              // 11 bytes
        XCTAssertNil(RTPPacket([0x40, 0x60, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1]))         // Version 1
        XCTAssertNil(RTPPacket([0x90, 0x60, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0xBE]))      // Extension cut off
        XCTAssertNil(RTPPacket([0x90, 0x60, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0xBE, 0xDE, 0, 9]))  // Extension longer than the packet
        XCTAssertNil(RTPPacket([0x82, 0x60, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]))  // 2 CSRCs, only 1 there
    }

    func testInterleavedFrame() {
        let packet = [UInt8](repeating: 7, count: 300)
        let frame = interleaved(packet, channel: 2)
        XCTAssertEqual(Array(frame.prefix(4)), [0x24, 2, 0x01, 0x2C])   // "$", channel, 300 big-endian
        XCTAssertEqual(Array(frame.dropFirst(4)), packet)
    }
}

final class H264DepacketizerTests: XCTestCase {
    let sps: [UInt8] = [0x67, 0x42, 0xC0, 0x1E, 0xDA]
    let pps: [UInt8] = [0x68, 0xCE, 0x3C, 0x80]
    let idr: [UInt8] = [0x65, 0x88, 0x84, 0x00, 0x33]
    let slice: [UInt8] = [0x41, 0x9A, 0x02, 0x04]

    func testSingleNALWithMarker() throws {
        let d = H264Depacketizer()
        let unit = try XCTUnwrap(d.push(rtp(seq: 1, idr)))
        XCTAssertEqual(unit.nalUnits, [idr])
        XCTAssertEqual(unit.timestamp, 3000)
        XCTAssertTrue(unit.isKeyframe)
    }

    func testNoKeyframeWithoutIDR() throws {
        let d = H264Depacketizer()
        let unit = try XCTUnwrap(d.push(rtp(seq: 1, slice)))
        XCTAssertEqual(unit.nalUnits, [slice])
        XCTAssertFalse(unit.isKeyframe)
    }

    // STAP-A: the SPS and the PPS go to the depacketizer, not to the access unit.
    func testSTAPASplitsTheNALs() throws {
        let d = H264Depacketizer()
        var stap: [UInt8] = [0x78]   // NRI 3, type 24
        for nal in [sps, pps, idr] { stap += [UInt8(nal.count >> 8), UInt8(nal.count & 0xFF)] + nal }
        let unit = try XCTUnwrap(d.push(rtp(seq: 1, stap)))
        XCTAssertEqual(unit.nalUnits, [idr])
        XCTAssertTrue(unit.isKeyframe)
        XCTAssertEqual(d.sps, sps)
        XCTAssertEqual(d.pps, pps)
        XCTAssertEqual(d.parameterSetVersion, 2)   // One step for the SPS, one for the PPS.
    }

    // FU-A: start, middle, end. The NAL header comes back from the indicator and the FU header.
    func testFUAReassembles() throws {
        let d = H264Depacketizer()
        let indicator: UInt8 = 0x60 | 28              // NRI of 0x65, type 28
        XCTAssertNil(d.push(rtp(seq: 10, marker: false, [indicator, 0x80 | 5, 1, 2, 3])))
        XCTAssertNil(d.push(rtp(seq: 11, marker: false, [indicator, 5, 4, 5])))
        let unit = try XCTUnwrap(d.push(rtp(seq: 12, marker: true, [indicator, 0x40 | 5, 6])))
        XCTAssertEqual(unit.nalUnits, [[0x65, 1, 2, 3, 4, 5, 6]])
        XCTAssertTrue(unit.isKeyframe)
    }

    // The parameter sets are kept apart and never prepended to the access unit.
    func testParameterSets() throws {
        let d = H264Depacketizer()
        d.setParameterSets(sps: sps, pps: pps)
        XCTAssertEqual(d.parameterSetVersion, 1)
        d.setParameterSets(sps: sps, pps: pps)          // The same: no change.
        XCTAssertEqual(d.parameterSetVersion, 1)
        XCTAssertNil(d.push(rtp(seq: 1, marker: false, sps)))   // The same SPS in band: no change.
        XCTAssertNil(d.push(rtp(seq: 2, marker: false, pps)))
        XCTAssertEqual(d.parameterSetVersion, 1)
        let unit = try XCTUnwrap(d.push(rtp(seq: 3, idr)))
        XCTAssertEqual(unit.nalUnits, [idr])
        d.setParameterSets(sps: sps + [0x01], pps: pps)  // A new SPS.
        XCTAssertEqual(d.parameterSetVersion, 2)
    }

    // A frame with no marker ends when the next timestamp comes.
    func testTimestampChangeEndsAFrame() throws {
        let d = H264Depacketizer()
        XCTAssertNil(d.push(rtp(seq: 1, ts: 3000, marker: false, idr)))
        let unit = try XCTUnwrap(d.push(rtp(seq: 2, ts: 6000, marker: false, slice)))
        XCTAssertEqual(unit.nalUnits, [idr])
        XCTAssertEqual(unit.timestamp, 3000)
    }

    // A lost packet drops the frame, and the next frames wait for a keyframe.
    func testLossWaitsForTheNextKeyframe() throws {
        let d = H264Depacketizer()
        XCTAssertNotNil(d.push(rtp(seq: 1, ts: 3000, idr)))
        XCTAssertNil(d.push(rtp(seq: 3, ts: 6000, slice)))     // seq 2 is lost
        XCTAssertNil(d.push(rtp(seq: 4, ts: 9000, slice)))     // refers to the lost frame
        XCTAssertEqual(d.droppedFrames, 2)
        let unit = try XCTUnwrap(d.push(rtp(seq: 5, ts: 12000, idr)))
        XCTAssertTrue(unit.isKeyframe)
        XCTAssertNotNil(d.push(rtp(seq: 6, ts: 15000, slice)))
    }

    // What the phone at the baby sends, the parent reads back: small NALs whole, a big one in FU-A.
    func testPacketizerRoundTrip() throws {
        let sei: [UInt8] = [0x06, 0x05, 0x01, 0xFF, 0x80]
        var big: [UInt8] = [0x65]
        for i in 0..<3000 { big.append(UInt8(truncatingIfNeeded: i * 7 + 1)) }
        var packetizer = RTPPacketizer(payloadType: 96)
        let packets = packetizer.h264([sps, pps, sei, big], timestamp: 90_000, maxPayload: 1400)

        XCTAssertEqual(packets.count, 6)   // SPS, PPS, SEI, and the IDR in 3 fragments of 1398 bytes.
        let d = H264Depacketizer()
        var units: [H264AccessUnit] = []
        for (i, bytes) in packets.enumerated() {
            XCTAssertLessThanOrEqual(bytes.count - 12, 1400)
            let p = try XCTUnwrap(RTPPacket(bytes))
            XCTAssertEqual(p.payloadType, 96)
            XCTAssertEqual(p.timestamp, 90_000)
            XCTAssertEqual(p.marker, i == packets.count - 1)
            if let unit = d.push(p) { units.append(unit) }
        }
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units.first?.nalUnits, [sei, big])
        XCTAssertEqual(units.first?.isKeyframe, true)
        XCTAssertEqual(d.sps, sps)
        XCTAssertEqual(d.pps, pps)
    }

    func testPacketizerSequenceAndSSRC() throws {
        var packetizer = RTPPacketizer(payloadType: 8)
        let a = try XCTUnwrap(RTPPacket(packetizer.packet([1, 2], timestamp: 160, marker: false)))
        let second = packetizer.packet([3], timestamp: 320, marker: false)
        let b = try XCTUnwrap(RTPPacket(second))
        XCTAssertEqual(b.sequence, a.sequence &+ 1)
        XCTAssertEqual(b.payloadType, 8)
        let ssrc = UInt32(second[8]) << 24 | UInt32(second[9]) << 16 | UInt32(second[10]) << 8 | UInt32(second[11])
        XCTAssertEqual(ssrc, packetizer.ssrc)
    }
}
