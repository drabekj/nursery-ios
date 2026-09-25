import Foundation
import Network

/// The Bonjour type of the iPhone at the baby. It must also be in NSBonjourServices.
enum BabyService {
    static let type = "_chuvicka._tcp"
}

/// A small RTSP server on the iPhone at the baby. It speaks the same RTSP as go2rtc,
/// so the parent app reads it with the same client: RTP interleaved over TCP,
/// H.264 video and G.711 A-law sound. It also answers `GET /<code>/frame.jpeg` for a photo.
///
/// The phones find each other with Bonjour, on the home Wi-Fi or directly (peer-to-peer Wi-Fi).
/// Nothing goes to the internet. The pairing code is the path, so a phone without the code
/// gets 401 and no sound.
///
/// All the state is on `queue`.
final class BabyServer: @unchecked Sendable {
    let queue = DispatchQueue(label: "nursery.baby.server", qos: .userInteractive)

    /// The count of parents that receive the stream now. It runs on the main queue.
    var onClients: ((Int) -> Void)?
    /// A parent started to play. The encoder must make a keyframe now.
    var onNeedKeyframe: (() -> Void)?
    /// A parent asked for a photo. The callback gets a JPEG, or nil.
    var onFrameRequest: ((@escaping @Sendable (Data?) -> Void) -> Void)?

    private let code: String
    private let hasVideo: Bool
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var sps: [UInt8]?
    private var pps: [UInt8]?

    init(code: String, video: Bool) {
        self.code = code
        self.hasVideo = video
    }

    // MARK: Start and stop

    func start(name: String) throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true         // Also with no router: the phones connect directly.
        params.serviceClass = .interactiveVideo
        let listener = try NWListener(using: params)
        listener.service = NWListener.Service(name: name, type: BabyService.type)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { Log.shared.add("baby server failed: \(error)") }
        }
        listener.start(queue: queue)
        self.listener = listener
        Log.shared.add("baby server started as \(name)")
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for s in self.sessions.values { s.close() }
            self.sessions.removeAll()
            self.reportClients()
        }
    }

    // MARK: The media, from the capture

    /// One H.264 access unit, with no start codes. The SPS and the PPS come with each keyframe.
    func sendVideo(nals: [[UInt8]], timestamp: UInt32, keyframe: Bool, sps: [UInt8]?, pps: [UInt8]?) {
        queue.async {
            if let sps, let pps { self.sps = sps; self.pps = pps }
            var unit = nals
            // The parameter sets in the stream too: a parent that joins late needs no new DESCRIBE.
            if keyframe, let s = self.sps, let p = self.pps { unit = [s, p] + nals }
            for s in self.sessions.values where s.playing { s.sendVideo(unit, timestamp: timestamp, keyframe: keyframe) }
        }
    }

    /// 20 ms of A-law sound (160 bytes at 8 kHz).
    func sendAudio(_ aLaw: [UInt8], timestamp: UInt32) {
        queue.async {
            for s in self.sessions.values where s.playing { s.sendAudio(aLaw, timestamp: timestamp) }
        }
    }

    // MARK: The connections

    private func accept(_ conn: NWConnection) {
        let session = Session(connection: conn, server: self)
        sessions[ObjectIdentifier(session)] = session
        conn.stateUpdateHandler = { [weak self, weak session] state in
            guard let self, let session else { return }
            switch state {
            case .ready: session.receive()
            case .failed, .cancelled: self.remove(session)
            default: break
            }
        }
        conn.start(queue: queue)
    }

    fileprivate func remove(_ session: Session) {
        guard sessions.removeValue(forKey: ObjectIdentifier(session)) != nil else { return }
        session.close()
        if session.playing { Log.shared.add("parent left") }
        reportClients()
    }

    fileprivate func reportClients() {
        let n = sessions.values.filter(\.playing).count
        DispatchQueue.main.async { self.onClients?(n) }
    }

    fileprivate func started(_ session: Session) {
        Log.shared.add("parent connected")
        reportClients()
        onNeedKeyframe?()
    }

    fileprivate func requestKeyframe() { onNeedKeyframe?() }

    // MARK: The requests

    fileprivate func pathIsValid(_ uri: String) -> Bool {
        // "rtsp://host/482913?audio/trackID=1" or "/482913/frame.jpeg": the code is the first path part.
        let afterHost: Substring
        if let range = uri.range(of: "://") {
            let rest = uri[range.upperBound...]
            afterHost = rest.firstIndex(of: "/").map { rest[$0...] } ?? ""
        } else {
            afterHost = uri[...]
        }
        let first = afterHost.split(separator: "/").first.map { $0.split(separator: "?").first ?? "" } ?? ""
        return first == code
    }

    fileprivate func sdp(audioOnly: Bool) -> String {
        var s = "v=0\r\no=- 0 0 IN IP4 0.0.0.0\r\ns=Chuvicka\r\nt=0 0\r\n"
        if hasVideo && !audioOnly {
            s += "m=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n"
            var fmtp = "packetization-mode=1"
            if let sps, let pps {
                fmtp += ";sprop-parameter-sets=\(Data(sps).base64EncodedString()),\(Data(pps).base64EncodedString())"
            }
            s += "a=fmtp:96 \(fmtp)\r\na=control:trackID=0\r\n"
        }
        s += "m=audio 0 RTP/AVP 8\r\na=rtpmap:8 PCMA/8000\r\na=control:trackID=1\r\n"
        return s
    }

    fileprivate func frame(_ done: @escaping @Sendable (Data?) -> Void) {
        guard hasVideo, let onFrameRequest else { done(nil); return }
        onFrameRequest(done)
    }
}

/// One parent. It reads the requests, and sends RTP to the channels that SETUP chose.
private final class Session {
    let connection: NWConnection
    weak var server: BabyServer?
    private(set) var playing = false
    private var buffer: [UInt8] = []
    private var sessionID = String(UInt32.random(in: 100_000...UInt32.max))
    private var videoChannel: UInt8?
    private var audioChannel: UInt8?
    private var video = RTPPacketizer(payloadType: 96)
    private var audio = RTPPacketizer(payloadType: 8)
    /// The bytes given to the connection that it did not send yet. A slow Wi-Fi fills it.
    private var inFlight = 0
    private var waitForKeyframe = true
    private var closed = false

    init(connection: NWConnection, server: BabyServer) {
        self.connection = connection
        self.server = server
    }

    func close() {
        guard !closed else { return }
        closed = true
        playing = false
        connection.cancel()
    }

    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(contentsOf: data); self.parse() }
            if error != nil || complete { self.server?.remove(self); return }
            self.receive()
        }
    }

    // MARK: Sending

    func sendVideo(_ nals: [[UInt8]], timestamp: UInt32, keyframe: Bool) {
        guard let channel = videoChannel else { return }
        if waitForKeyframe {
            guard keyframe else { return }
            waitForKeyframe = false
        }
        // Too much is waiting: skip the picture until the next keyframe. The sound goes on.
        if inFlight > 768 * 1024 {
            waitForKeyframe = true
            server?.requestKeyframe()
            return
        }
        var bytes: [UInt8] = []
        for p in video.h264(nals, timestamp: timestamp) { bytes += interleaved(p, channel: channel) }
        write(bytes)
    }

    func sendAudio(_ payload: [UInt8], timestamp: UInt32) {
        guard let channel = audioChannel, inFlight < 2 * 1024 * 1024 else { return }
        write(interleaved(audio.packet(payload[...], timestamp: timestamp, marker: false), channel: channel))
    }

    private func write(_ bytes: [UInt8]) {
        inFlight += bytes.count
        let n = bytes.count
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] _ in
            self?.inFlight -= n        // The completion runs on the server queue.
        })
    }

    // MARK: The requests

    private func parse() {
        while !buffer.isEmpty {
            if buffer[0] == 0x24 {                         // Interleaved data from the parent (RTCP): skip it.
                guard buffer.count >= 4 else { return }
                let length = Int(buffer[2]) << 8 | Int(buffer[3])
                guard buffer.count >= 4 + length else { return }
                buffer.removeFirst(4 + length)
                continue
            }
            guard let end = headerEnd() else {
                if buffer.count > 16 * 1024 { server?.remove(self) }
                return
            }
            let head = String(decoding: buffer[0..<end], as: UTF8.self)
            var lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst().split(separator: " ")
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let bodyLength = Int(headers["content-length"] ?? "0") ?? 0
            guard buffer.count >= end + 4 + bodyLength else { return }
            buffer.removeFirst(end + 4 + bodyLength)
            guard requestLine.count >= 3 else { continue }
            handle(method: String(requestLine[0]), uri: String(requestLine[1]),
                   version: String(requestLine[2]), headers: headers)
        }
    }

    private func headerEnd() -> Int? {
        guard buffer.count >= 4 else { return nil }
        for i in 0...(buffer.count - 4) where buffer[i] == 13 && buffer[i + 1] == 10 && buffer[i + 2] == 13 && buffer[i + 3] == 10 {
            return i
        }
        return nil
    }

    private func handle(method: String, uri: String, version: String, headers: [String: String]) {
        guard let server else { return }
        let cseq = headers["cseq"] ?? "0"

        if version.hasPrefix("HTTP") {
            guard method == "GET", server.pathIsValid(uri), uri.hasSuffix("/frame.jpeg") else {
                httpReply("401 Unauthorized", type: "text/plain", body: Data("wrong code".utf8))
                return
            }
            server.frame { [weak self] jpeg in
                server.queue.async {
                    guard let self else { return }
                    if let jpeg { self.httpReply("200 OK", type: "image/jpeg", body: jpeg) }
                    else { self.httpReply("503 Service Unavailable", type: "text/plain", body: Data("no picture".utf8)) }
                }
            }
            return
        }

        if method != "OPTIONS" && method != "GET_PARAMETER" && !server.pathIsValid(uri) {
            reply(401, "Unauthorized", cseq: cseq)
            Log.shared.add("baby server: a phone with a wrong code")
            return
        }
        switch method {
        case "OPTIONS":
            reply(200, "OK", cseq: cseq, ["Public": "OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN, GET_PARAMETER"])
        case "GET_PARAMETER":
            reply(200, "OK", cseq: cseq, ["Session": sessionID])
        case "DESCRIBE":
            let sdp = server.sdp(audioOnly: uri.contains("?audio"))
            reply(200, "OK", cseq: cseq, ["Content-Type": "application/sdp"], body: sdp)
        case "SETUP":
            let transport = headers["transport"] ?? ""
            var channel: UInt8 = uri.contains("trackID=0") ? 0 : 2
            if let range = transport.range(of: "interleaved=") {
                let digits = transport[range.upperBound...].prefix { $0.isNumber }
                channel = UInt8(digits) ?? channel
            }
            if uri.contains("trackID=0") { videoChannel = channel } else { audioChannel = channel }
            reply(200, "OK", cseq: cseq, [
                "Transport": "RTP/AVP/TCP;unicast;interleaved=\(channel)-\(channel + 1)",
                "Session": "\(sessionID);timeout=60",
            ])
        case "PLAY":
            reply(200, "OK", cseq: cseq, ["Session": sessionID, "Range": "npt=0.000-"])
            if !playing {
                playing = true
                waitForKeyframe = true
                server.started(self)
            }
        case "TEARDOWN":
            reply(200, "OK", cseq: cseq, ["Session": sessionID])
            server.remove(self)
        default:
            reply(405, "Method Not Allowed", cseq: cseq)
        }
    }

    private func reply(_ status: Int, _ reason: String, cseq: String, _ headers: [String: String] = [:], body: String = "") {
        var text = "RTSP/1.0 \(status) \(reason)\r\nCSeq: \(cseq)\r\nServer: Chuvicka\r\n"
        for (k, v) in headers { text += "\(k): \(v)\r\n" }
        let bodyData = Array(body.utf8)
        if !bodyData.isEmpty { text += "Content-Length: \(bodyData.count)\r\n" }
        text += "\r\n"
        write(Array(text.utf8) + bodyData)
    }

    private func httpReply(_ status: String, type: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.server?.remove(self)
        })
    }
}
