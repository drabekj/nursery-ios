import XCTest
@testable import Nursery

/// The SDP of the go2rtc restream: H.264 video and PCMA audio.
final class SDPTests: XCTestCase {
    // As go2rtc sends it, with CRLF line ends.
    let goSDP = [
        "v=0",
        "o=- 0 0 IN IP4 0.0.0.0",
        "s=-",
        "t=0 0",
        "m=video 0 RTP/AVP 96",
        "a=rtpmap:96 H264/90000",
        "a=fmtp:96 packetization-mode=1; sprop-parameter-sets=Z2QAH6zZQFAFuwEQAAADABAAAAMDKPGDGWA=,aOvjyyLA; profile-level-id=64001F",
        "a=control:trackID=0",
        "m=audio 0 RTP/AVP 8",
        "a=rtpmap:8 PCMA/8000",
        "a=control:trackID=1",
        "",
    ].joined(separator: "\r\n")

    let sps: [UInt8] = [0x67, 0x64, 0x00, 0x1F, 0xAC, 0xD9, 0x40, 0x50, 0x05, 0xBB, 0x01, 0x10, 0x00,
                        0x00, 0x03, 0x00, 0x10, 0x00, 0x00, 0x03, 0x03, 0x28, 0xF1, 0x83, 0x19, 0x60]
    let pps: [UInt8] = [0x68, 0xEB, 0xE3, 0xCB, 0x22, 0xC0]

    func testParsesTheTracks() {
        let tracks = SDP.parse(goSDP)
        XCTAssertEqual(tracks.count, 2)
        guard tracks.count == 2 else { return }

        let video = tracks[0]
        XCTAssertEqual(video.kind, .video)
        XCTAssertEqual(video.payloadType, 96)
        XCTAssertEqual(video.codec, "H264")
        XCTAssertEqual(video.clockRate, 90000)
        XCTAssertEqual(video.control, "trackID=0")
        XCTAssertEqual(video.fmtp["packetization-mode"], "1")
        XCTAssertEqual(video.fmtp["profile-level-id"], "64001F")

        let audio = tracks[1]
        XCTAssertEqual(audio.kind, .audio)
        XCTAssertEqual(audio.payloadType, 8)
        XCTAssertEqual(audio.codec, "PCMA")
        XCTAssertEqual(audio.clockRate, 8000)
        XCTAssertEqual(audio.control, "trackID=1")
        XCTAssertNil(audio.h264ParameterSets)

        XCTAssertTrue(RTSPClient.isUsable(video))
        XCTAssertTrue(RTSPClient.isUsable(audio))
    }

    func testDecodesTheParameterSets() {
        let video = SDP.parse(goSDP).first
        let sets = video?.h264ParameterSets
        XCTAssertEqual(sets?.sps, sps)
        XCTAssertEqual(sets?.pps, pps)
    }

    // Some servers omit the base64 padding.
    func testDecodesTheParameterSetsWithNoPadding() {
        let text = goSDP.replacingOccurrences(of: "GWA=,", with: "GWA,")
        let sets = SDP.parse(text).first?.h264ParameterSets
        XCTAssertEqual(sets?.sps, sps)
        XCTAssertEqual(sets?.pps, pps)
    }

    // PCMU (0) and PCMA (8) are static payload types, often with no rtpmap line.
    func testStaticPayloadTypesWithNoRtpmap() {
        let text = "v=0\nm=audio 0 RTP/AVP 0\na=control:audio\n"
        let tracks = SDP.parse(text)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.codec, "PCMU")
        XCTAssertEqual(tracks.first?.clockRate, 8000)
        XCTAssertEqual(tracks.first?.control, "audio")
    }

    func testOtherCodecsAreNotUsable() {
        let text = "v=0\nm=audio 0 RTP/AVP 97\na=rtpmap:97 MPEG4-GENERIC/48000/2\n"
        let track = SDP.parse(text).first
        XCTAssertEqual(track?.codec, "MPEG4-GENERIC")
        XCTAssertEqual(track?.clockRate, 48000)
        XCTAssertFalse(track.map(RTSPClient.isUsable) ?? true)
    }

    func testControlURL() {
        let base = "rtsp://192.168.0.10:8554/pokoj"
        // Relative: joined to the base with one "/".
        XCTAssertEqual(SDP.controlURL(base: base, control: "trackID=0"), base + "/trackID=0")
        XCTAssertEqual(SDP.controlURL(base: base + "/", control: "trackID=0"), base + "/trackID=0")
        // Absolute: as it is, in any case.
        XCTAssertEqual(SDP.controlURL(base: base, control: "rtsp://10.0.0.1/x/track1"), "rtsp://10.0.0.1/x/track1")
        XCTAssertEqual(SDP.controlURL(base: base, control: "RTSP://10.0.0.1/x"), "RTSP://10.0.0.1/x")
        // "*" or none: the base.
        XCTAssertEqual(SDP.controlURL(base: base, control: "*"), base)
        XCTAssertEqual(SDP.controlURL(base: base, control: ""), base)
    }
}
