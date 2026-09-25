import Foundation

// The pure protocol layer: SDP, RTP, H.264 depacketization, and G.711.
// It uses Foundation only. Tools/rtsp_check.py holds the same algorithm in Python,
// and that script is tested against go2rtc.

// MARK: - SDP

struct SDPTrack: Equatable {
    enum Kind: String { case video, audio, other }
    let kind: Kind
    let payloadType: UInt8
    let codec: String          // Upper case, for example "H264" or "PCMA".
    let clockRate: Int
    let control: String
    let fmtp: [String: String]

    /// The SPS and the PPS from `sprop-parameter-sets`, if the SDP has them.
    var h264ParameterSets: (sps: [UInt8], pps: [UInt8])? {
        guard let sprop = fmtp["sprop-parameter-sets"] else { return nil }
        var sps: [UInt8]?, pps: [UInt8]?
        for part in sprop.split(separator: ",") {
            var b64 = part.trimmingCharacters(in: .whitespaces)
            b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)   // Some servers omit the padding.
            guard let data = Data(base64Encoded: b64), let first = data.first else { continue }
            switch first & 0x1F {
            case 7: sps = [UInt8](data)
            case 8: pps = [UInt8](data)
            default: break
            }
        }
        if let sps, let pps { return (sps, pps) }
        return nil
    }
}

enum SDP {
    static func parse(_ text: String) -> [SDPTrack] {
        var tracks: [SDPTrack] = []
        let lines = text.replacingOccurrences(of: "\r", with: "").split(separator: "\n").map(String.init)
        var sections: [[String]] = []
        for line in lines {
            if line.hasPrefix("m=") { sections.append([line]) }
            else if !sections.isEmpty { sections[sections.count - 1].append(line) }
        }
        for section in sections {
            // m=video 0 RTP/AVP 96
            let m = section[0].dropFirst(2).split(separator: " ")
            guard m.count >= 4, let pt = UInt8(m[3]) else { continue }
            let kind = SDPTrack.Kind(rawValue: String(m[0])) ?? .other
            var codec = "", rate = 0, control = "", fmtp: [String: String] = [:]
            for line in section.dropFirst() {
                if line.hasPrefix("a=rtpmap:\(pt) ") {
                    // a=rtpmap:96 H264/90000
                    let spec = line.split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
                    let parts = spec.split(separator: "/")
                    codec = parts.first.map { $0.uppercased() } ?? ""
                    rate = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                } else if line.hasPrefix("a=fmtp:\(pt) ") {
                    let params = line.split(separator: " ", maxSplits: 1).last ?? ""
                    for item in params.split(separator: ";") {
                        let kv = item.trimmingCharacters(in: .whitespaces)
                        guard let eq = kv.firstIndex(of: "=") else { continue }
                        // Split at the first "=" only. Base64 values end with "=".
                        fmtp[String(kv[..<eq]).lowercased()] = String(kv[kv.index(after: eq)...])
                    }
                } else if line.hasPrefix("a=control:") {
                    control = String(line.dropFirst("a=control:".count))
                }
            }
            // The static payload types have no rtpmap line.
            if codec.isEmpty {
                switch pt {
                case 0: codec = "PCMU"; rate = 8000
                case 8: codec = "PCMA"; rate = 8000
                default: break
                }
            }
            tracks.append(SDPTrack(kind: kind, payloadType: pt, codec: codec,
                                   clockRate: rate, control: control, fmtp: fmtp))
        }
        return tracks
    }

    /// The URL for SETUP. go2rtc sends no Content-Base, so the request URL is the base.
    static func controlURL(base: String, control: String) -> String {
        if control.isEmpty || control == "*" { return base }
        if control.lowercased().hasPrefix("rtsp://") { return control }
        return base.hasSuffix("/") ? base + control : base + "/" + control
    }
}

// MARK: - RTP

struct RTPPacket {
    let payloadType: UInt8
    let marker: Bool
    let sequence: UInt16
    let timestamp: UInt32
    let payload: ArraySlice<UInt8>

    init?(_ b: [UInt8]) {
        guard b.count >= 12, b[0] >> 6 == 2 else { return nil }
        let csrcCount = Int(b[0] & 0x0F)
        var start = 12 + 4 * csrcCount
        var end = b.count
        if b[0] & 0x10 != 0 {                      // The header extension.
            guard b.count >= start + 4 else { return nil }
            start += 4 + 4 * (Int(b[start + 2]) << 8 | Int(b[start + 3]))
        }
        if b[0] & 0x20 != 0, let pad = b.last {    // The padding.
            end -= Int(pad)
        }
        guard start <= end else { return nil }
        payloadType = b[1] & 0x7F
        marker = b[1] & 0x80 != 0
        sequence = UInt16(b[2]) << 8 | UInt16(b[3])
        timestamp = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        payload = b[start..<end]
    }
}

// MARK: - H.264 (RFC 6184)

struct H264AccessUnit {
    let nalUnits: [[UInt8]]   // No start codes. The SPS and the PPS are removed.
    let timestamp: UInt32
    let isKeyframe: Bool
}

/// It joins the RTP packets of one frame into one access unit.
/// It supports single NAL units, STAP-A (24), and FU-A (28).
final class H264Depacketizer {
    private(set) var sps: [UInt8]?
    private(set) var pps: [UInt8]?
    /// It increments each time that the SPS or the PPS changes.
    private(set) var parameterSetVersion = 0

    private var nals: [[UInt8]] = []
    private var fragment: [UInt8]?
    private var timestamp: UInt32?
    private var lastSequence: UInt16?
    private var damaged = false
    /// After a damaged frame, the next frames refer to a frame that is missing.
    /// Hold them until the next keyframe. A frozen picture is better than a smeared one.
    private var waitForKeyframe = false
    /// The count of dropped frames, for the diagnosis.
    private(set) var droppedFrames = 0

    func setParameterSets(sps: [UInt8], pps: [UInt8]) {
        if sps != self.sps || pps != self.pps {
            self.sps = sps; self.pps = pps; parameterSetVersion += 1
        }
    }

    /// It returns an access unit when a frame is complete. A damaged frame is dropped.
    func push(_ packet: RTPPacket) -> H264AccessUnit? {
        var output: H264AccessUnit?
        if let last = lastSequence, packet.sequence != last &+ 1 {
            damaged = true            // A packet is lost. The frame cannot decode.
            fragment = nil
        }
        lastSequence = packet.sequence

        if let ts = timestamp, ts != packet.timestamp, !nals.isEmpty {
            output = flush()          // A frame had no marker bit.
        }
        timestamp = packet.timestamp

        let p = packet.payload
        guard let first = p.first else { return output }
        let type = first & 0x1F
        switch type {
        case 1...23:
            add(Array(p))
        case 24:                      // STAP-A
            var i = p.startIndex + 1
            while i + 2 <= p.endIndex {
                let size = Int(p[i]) << 8 | Int(p[i + 1])
                i += 2
                guard size > 0, i + size <= p.endIndex else { break }
                add(Array(p[i..<i + size]))
                i += size
            }
        case 28:                      // FU-A
            guard p.count >= 2 else { break }
            let header = p[p.startIndex + 1]
            let body = p[(p.startIndex + 2)...]
            if header & 0x80 != 0 {
                fragment = [(first & 0xE0) | (header & 0x1F)] + body
            } else if fragment != nil {
                fragment! += body
            }
            if header & 0x40 != 0, let nal = fragment {
                fragment = nil
                add(nal)
            }
        default:
            break
        }
        if packet.marker, !nals.isEmpty {
            output = flush()
        }
        return output
    }

    private func add(_ nal: [UInt8]) {
        guard let first = nal.first else { return }
        switch first & 0x1F {
        case 7: if nal != sps { sps = nal; parameterSetVersion += 1 }
        case 8: if nal != pps { pps = nal; parameterSetVersion += 1 }
        case 9: break                 // The access unit delimiter is not necessary.
        default: nals.append(nal)
        }
    }

    private func flush() -> H264AccessUnit? {
        defer { nals = []; damaged = false }
        guard !damaged, let ts = timestamp else {
            droppedFrames += 1
            waitForKeyframe = true
            return nil
        }
        let key = nals.contains { $0.first.map { $0 & 0x1F == 5 } ?? false }
        let hasSlice = nals.contains { $0.first.map { (1...5).contains($0 & 0x1F) } ?? false }
        guard hasSlice else { return nil }
        if waitForKeyframe {
            guard key else { droppedFrames += 1; return nil }
            waitForKeyframe = false
        }
        return H264AccessUnit(nalUnits: nals, timestamp: ts, isKeyframe: key)
    }
}

// MARK: - G.711

enum G711 {
    static let aLaw: [Int16] = (0...255).map { decodeALaw(UInt8($0)) }
    static let uLaw: [Int16] = (0...255).map { decodeULaw(UInt8($0)) }

    static func decodeALaw(_ value: UInt8) -> Int16 {
        let a = value ^ 0x55
        var t = Int(a & 0x0F) << 4
        let segment = Int(a & 0x70) >> 4
        switch segment {
        case 0: t += 8
        case 1: t += 0x108
        default: t += 0x108; t <<= segment - 1
        }
        return Int16(a & 0x80 != 0 ? t : -t)
    }

    static func decodeULaw(_ value: UInt8) -> Int16 {
        let u = ~value
        var t = (Int(u & 0x0F) << 3) + 0x84
        t <<= Int(u & 0x70) >> 4
        return Int16(u & 0x80 != 0 ? 0x84 - t : t - 0x84)
    }
}

// MARK: - The sending side, for the iPhone at the baby

extension G711 {
    /// Linear 16-bit PCM to A-law, as in the ITU reference (g711.c, linear2alaw).
    static func encodeALaw(_ pcm: Int16) -> UInt8 {
        var p = Int(pcm) >> 3
        let mask: Int
        if p >= 0 { mask = 0xD5 } else { mask = 0x55; p = -p - 1 }
        let segmentEnds = [0x1F, 0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF]
        var segment = 0
        while segment < 8 && p > segmentEnds[segment] { segment += 1 }
        if segment >= 8 { return UInt8(0x7F ^ mask) }
        var a = segment << 4
        a |= segment < 2 ? (p >> 1) & 0x0F : (p >> segment) & 0x0F
        return UInt8(a ^ mask)
    }
}

/// It makes RTP packets (RFC 3550) for one track of one receiver.
struct RTPPacketizer {
    let payloadType: UInt8
    let ssrc: UInt32
    private(set) var sequence = UInt16.random(in: 0...UInt16.max)

    init(payloadType: UInt8) {
        self.payloadType = payloadType
        ssrc = UInt32.random(in: 1...UInt32.max)
    }

    mutating func packet(_ payload: ArraySlice<UInt8>, timestamp: UInt32, marker: Bool) -> [UInt8] {
        var b = [UInt8]()
        b.reserveCapacity(12 + payload.count)
        b.append(0x80)
        b.append((marker ? 0x80 : 0) | payloadType)
        b.append(UInt8(sequence >> 8)); b.append(UInt8(sequence & 0xFF))
        for shift in stride(from: 24, through: 0, by: -8) { b.append(UInt8((timestamp >> UInt32(shift)) & 0xFF)) }
        for shift in stride(from: 24, through: 0, by: -8) { b.append(UInt8((ssrc >> UInt32(shift)) & 0xFF)) }
        b.append(contentsOf: payload)
        sequence &+= 1
        return b
    }

    /// The RTP packets of one H.264 access unit: a single NAL unit, or FU-A fragments (RFC 6184).
    mutating func h264(_ nals: [[UInt8]], timestamp: UInt32, maxPayload: Int = 1400) -> [[UInt8]] {
        var out: [[UInt8]] = []
        for (n, nal) in nals.enumerated() {
            guard let header = nal.first else { continue }
            let last = n == nals.count - 1
            if nal.count <= maxPayload {
                out.append(packet(nal[...], timestamp: timestamp, marker: last))
                continue
            }
            let indicator = (header & 0xE0) | 28
            var offset = 1
            while offset < nal.count {
                let end = min(offset + maxPayload - 2, nal.count)
                var fu: [UInt8] = [indicator, header & 0x1F]
                if offset == 1 { fu[1] |= 0x80 }               // The start bit.
                if end == nal.count { fu[1] |= 0x40 }          // The end bit.
                fu.append(contentsOf: nal[offset..<end])
                out.append(packet(fu[...], timestamp: timestamp, marker: last && end == nal.count))
                offset = end
            }
        }
        return out
    }
}

/// One RTP packet in the RTSP interleaved frame ("$", channel, length).
func interleaved(_ packet: [UInt8], channel: UInt8) -> [UInt8] {
    [0x24, channel, UInt8(packet.count >> 8), UInt8(packet.count & 0xFF)] + packet
}
