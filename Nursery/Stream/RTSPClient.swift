import CryptoKit
import Foundation
import Network

/// A flag for one resume of a continuation. Only RTSPClient.queue touches it.
private final class ResumeOnce: @unchecked Sendable { var done = false }

/// A small RTSP client for go2rtc. It uses RTP interleaved over the one TCP connection.
/// Only go2rtc reads the camera. This client reads the go2rtc restream, never the camera.
///
/// All the state is on `queue`. The callbacks also run on `queue`.
final class RTSPClient: @unchecked Sendable {
    enum Failure: LocalizedError {
        case unreachable(String), closed, timeout(String), status(Int, String), noUsableTrack, badURL

        var errorDescription: String? {
            switch self {
            case .unreachable(let why): return "Server neodpovídá (\(why))."
            case .closed: return "Server ukončil spojení."
            case .timeout(let what): return "Žádná odpověď na \(what)."
            case .status(401, "pairing"): return "Nesprávný párovací kód. Zadejte kód z telefonu u miminka."
            case .status(401, "login"): return "Kamera chce přihlášení. Zadejte uživatele a heslo kamery."
            case .status(401, _): return "Kamera odmítla uživatele nebo heslo."
            case .status(let code, let reason): return "Server odpověděl \(code) \(reason)."
            case .noUsableTrack: return "Stream nemá video H.264 ani zvuk G.711."
            case .badURL: return "Adresa streamu není platná."
            }
        }
    }

    struct Response {
        let status: Int
        let reason: String
        let headers: [String: String]   // The keys are lower case.
        let body: [UInt8]
    }

    struct Track {
        let sdp: SDPTrack
        let channel: UInt8               // The interleaved RTP channel. RTCP is channel + 1.
    }

    /// (channel, RTP packet). It runs on `queue`.
    var onPacket: ((UInt8, [UInt8]) -> Void)?
    /// It runs one time, on `queue`, when the connection ends for any reason.
    var onClose: ((Error?) -> Void)?

    let queue = DispatchQueue(label: "nursery.rtsp", qos: .userInteractive)
    private let url: String
    private let host: String
    private let port: UInt16
    /// The iPhone at the baby, as a Bonjour service. Then `host` and `port` are not used.
    private let endpoint: NWEndpoint?
    private var connection: NWConnection?
    private var buffer: [UInt8] = []
    private var readIndex = 0
    private var cseq = 0
    private var session: String?
    private var pending: [Int: (Result<Response, Error>) -> Void] = [:]
    private var keepAlive: DispatchSourceTimer?
    private var closed = false
    private var reported: [String] = []
    /// It fails a connect() that still waits, when stop() comes first. Else the caller waits forever.
    private var failConnect: ((Error) -> Void)?
    /// The addresses that the phone at the baby reported in DESCRIBE, for the time away from home.
    var serverAddresses: [String] { queue.sync { reported } }

    init(url: String, endpoint: NWEndpoint? = nil) throws {
        guard var u = URLComponents(string: url), u.scheme == "rtsp", let host = u.host else { throw Failure.badURL }
        // The user and the password leave the URL. They go only in the Authorization header,
        // hashed (Digest), after the camera asks for them.
        user = u.user
        password = u.password
        u.user = nil
        u.password = nil
        self.url = u.string ?? url
        self.host = host
        self.port = UInt16(u.port ?? 554)
        self.endpoint = endpoint
    }

    // MARK: Login (RFC 2617): IP cameras such as Tapo, Hikvision and Dahua ask for it

    private let user: String?
    private let password: String?
    private var challenge: [String: String]?        // The fields of WWW-Authenticate, and "scheme".
    private var nonceCount = 0

    private static func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `Digest realm="x", nonce="y", qop="auth"` to its fields.
    static func parseChallenge(_ header: String) -> [String: String] {
        var fields: [String: String] = ["scheme": header.split(separator: " ").first.map { $0.lowercased() } ?? ""]
        let pattern = try! NSRegularExpression(pattern: #"(\w+)=(?:"([^"]*)"|([^,\s]*))"#)
        let ns = header as NSString
        for m in pattern.matches(in: header, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: m.range(at: 1)).lowercased()
            let value = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ns.substring(with: m.range(at: 3))
            fields[key] = value
        }
        return fields
    }

    /// The Authorization header for one request. The caller is on `queue`.
    private func authorization(method: String, uri: String) -> String? {
        guard let c = challenge, let user, let password else { return nil }
        if c["scheme"] == "basic" {
            return "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        }
        let qop = c["qop"].map { value in value.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "auth" } } ?? false
        var cnonce = ""
        if qop {
            nonceCount += 1
            cnonce = String(format: "%08x", UInt32.random(in: 0...UInt32.max))
        }
        return Self.digestHeader(user: user, password: password, method: method, uri: uri,
                                 realm: c["realm"] ?? "", nonce: c["nonce"] ?? "", qop: qop,
                                 opaque: c["opaque"], nc: nonceCount, cnonce: cnonce)
    }

    /// The Digest header (RFC 2617). With `qop`, it uses qop=auth with `nc` and `cnonce`.
    /// It is pure, for the tests.
    static func digestHeader(user: String, password: String, method: String, uri: String,
                             realm: String, nonce: String, qop: Bool, opaque: String?,
                             nc: Int, cnonce: String) -> String {
        let ha1 = md5("\(user):\(realm):\(password)")
        let ha2 = md5("\(method):\(uri)")
        var header = "Digest username=\"\(user)\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(uri)\""
        if qop {
            let count = String(format: "%08x", nc)
            header += ", qop=auth, nc=\(count), cnonce=\"\(cnonce)\", response=\"\(md5("\(ha1):\(nonce):\(count):\(cnonce):auth:\(ha2)"))\""
        } else {
            header += ", response=\"\(md5("\(ha1):\(nonce):\(ha2)"))\""
        }
        if let opaque { header += ", opaque=\"\(opaque)\"" }
        return header
    }

    // MARK: The public steps

    /// It connects, reads the SDP, sets up the usable tracks, and starts the stream.
    /// `prepare` runs on `queue` before PLAY. Thus the first packet (a keyframe) is not lost.
    func start(prepare: @escaping ([Track]) -> Void) async throws -> [Track] {
        try await connect()
        _ = try? await request("OPTIONS", url)
        let describe = try await request("DESCRIBE", url, ["Accept": "application/sdp"])
        let base = describe.headers["content-base"] ?? describe.headers["content-location"] ?? url
        let sdp = SDP.parse(String(decoding: describe.body, as: UTF8.self))
        let addresses = (describe.headers["x-chuvicka-addresses"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        queue.sync { self.reported = addresses }

        var tracks: [Track] = []
        for t in sdp where Self.isUsable(t) {
            // One video track and one audio track are enough.
            if tracks.contains(where: { $0.sdp.kind == t.kind }) { continue }
            let channel = UInt8(tracks.count * 2)
            let setup = try await request("SETUP", SDP.controlURL(base: base, control: t.control),
                                          ["Transport": "RTP/AVP/TCP;unicast;interleaved=\(channel)-\(channel + 1)"])
            if session == nil, let s = setup.headers["session"] {
                let parts = s.split(separator: ";")
                let id = parts.first.map { $0.trimmingCharacters(in: .whitespaces) }
                queue.sync { self.session = id }       // send() reads it on the queue.
                let timeout = parts.dropFirst().first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("timeout=") }
                    .flatMap { Int($0.split(separator: "=").last ?? "") } ?? 60
                queue.async { self.startKeepAlive(every: max(5, timeout / 3)) }
            }
            tracks.append(Track(sdp: t, channel: channel))
        }
        guard !tracks.isEmpty else { throw Failure.noUsableTrack }
        let ready = tracks
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { prepare(ready); cont.resume() }
        }
        _ = try await request("PLAY", url, ["Range": "npt=0.000-"])
        return tracks
    }

    /// DESCRIBE only, then it closes: the tracks of the stream, with no SETUP and no PLAY.
    /// The stream discovery uses it to read the picture size from the SDP.
    func describe() async throws -> [SDPTrack] {
        defer { stop() }
        try await connect()
        let r = try await request("DESCRIBE", url, ["Accept": "application/sdp"])
        return SDP.parse(String(decoding: r.body, as: UTF8.self))
    }

    func stop() {
        queue.async {
            guard !self.closed else { return }
            if self.session != nil { self.send("TEARDOWN", self.url, [:]) }
            self.finish(nil)
        }
    }

    static func isUsable(_ t: SDPTrack) -> Bool {
        (t.kind == .video && t.codec == "H264") || (t.kind == .audio && (t.codec == "PCMA" || t.codec == "PCMU"))
    }

    // MARK: The connection

    private func connect() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.closed else { cont.resume(throwing: Failure.closed); return }   // stop() came first.
                let tcp = NWProtocolTCP.Options()
                tcp.noDelay = true
                tcp.connectionTimeout = 5
                tcp.enableKeepalive = true
                tcp.keepaliveIdle = 5
                let params = NWParameters(tls: nil, tcp: tcp)
                params.serviceClass = .interactiveVideo
                let conn: NWConnection
                if let endpoint = self.endpoint {
                    params.includePeerToPeer = true      // Also with no router between the phones.
                    conn = NWConnection(to: endpoint, using: params)
                } else {
                    conn = NWConnection(host: NWEndpoint.Host(self.host),
                                        port: NWEndpoint.Port(rawValue: self.port) ?? 554, using: params)
                }
                self.connection = conn
                let once = ResumeOnce()
                self.failConnect = { error in
                    if !once.done { once.done = true; cont.resume(throwing: error) }
                }
                conn.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.failConnect = nil
                        if !once.done { once.done = true; cont.resume(); self.receive() }
                    case .waiting(let error):
                        // A "waiting" connection does not fail by itself. Stop it here.
                        if !once.done { once.done = true; cont.resume(throwing: Failure.unreachable(error.localizedDescription)) }
                        self.finish(Failure.unreachable(error.localizedDescription))
                    case .failed(let error):
                        if !once.done { once.done = true; cont.resume(throwing: Failure.unreachable(error.localizedDescription)) }
                        self.finish(Failure.unreachable(error.localizedDescription))
                    case .cancelled:
                        if !once.done { once.done = true; cont.resume(throwing: Failure.closed) }
                    default:
                        break
                    }
                }
                conn.start(queue: self.queue)
            }
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.buffer.append(contentsOf: data)
                self.parse()
            }
            if let error { self.finish(error); return }
            if isComplete { self.finish(Failure.closed); return }
            self.receive()
        }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        keepAlive?.cancel()
        keepAlive = nil
        let waiting = pending
        pending = [:]
        waiting.values.forEach { $0(.failure(error ?? Failure.closed)) }
        failConnect?(error ?? Failure.closed)
        failConnect = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        onClose?(error)
        onClose = nil
        onPacket = nil
    }

    private func startKeepAlive(every seconds: Int) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(seconds), repeating: .seconds(seconds))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.send("OPTIONS", self.url, [:])   // go2rtc accepts OPTIONS as a keepalive.
        }
        timer.resume()
        keepAlive = timer
    }

    // MARK: The requests

    private func request(_ method: String, _ uri: String, _ headers: [String: String] = [:]) async throws -> Response {
        let r = try await exchange(method, uri, headers)
        if (200..<300).contains(r.status) { return r }
        if r.status == 401 {
            // The phone at the baby: a wrong pairing code. A camera: it asks for the login, one time.
            if endpoint != nil { throw Failure.status(401, "pairing") }
            let alreadyTried = queue.sync { challenge != nil }
            guard user != nil, !alreadyTried, let header = r.headers["www-authenticate"] else {
                throw Failure.status(401, user == nil ? "login" : "rejected")
            }
            queue.sync { challenge = Self.parseChallenge(header) }
            let again = try await exchange(method, uri, headers)
            if (200..<300).contains(again.status) { return again }
            throw Failure.status(again.status, again.status == 401 ? "rejected" : again.reason)
        }
        throw Failure.status(r.status, r.reason)
    }

    /// One request and its answer, of any status.
    private func exchange(_ method: String, _ uri: String, _ headers: [String: String]) async throws -> Response {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Response, Error>) in
            queue.async {
                guard !self.closed else { cont.resume(throwing: Failure.closed); return }
                let id = self.send(method, uri, headers)
                self.pending[id] = { result in
                    switch result {
                    case .success(let r): cont.resume(returning: r)
                    case .failure(let e): cont.resume(throwing: e)
                    }
                }
                self.queue.asyncAfter(deadline: .now() + 6) {
                    if let callback = self.pending.removeValue(forKey: id) {
                        callback(.failure(Failure.timeout(method)))
                        self.finish(Failure.timeout(method))
                    }
                }
            }
        }
    }

    /// It sends one request and returns its CSeq. The caller is on `queue`.
    @discardableResult
    private func send(_ method: String, _ uri: String, _ headers: [String: String]) -> Int {
        cseq += 1
        var text = "\(method) \(uri) RTSP/1.0\r\nCSeq: \(cseq)\r\nUser-Agent: Nursery/1.0\r\n"
        if let session { text += "Session: \(session)\r\n" }
        if let auth = authorization(method: method, uri: uri) { text += "Authorization: \(auth)\r\n" }
        for (k, v) in headers { text += "\(k): \(v)\r\n" }
        text += "\r\n"
        connection?.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
        return cseq
    }

    // MARK: The parser

    private func parse() {
        while !closed {
            let available = buffer.count - readIndex
            guard available > 0 else { break }
            let first = buffer[readIndex]
            if first == 0x24 {                          // "$": one interleaved packet.
                guard available >= 4 else { break }
                let channel = buffer[readIndex + 1]
                let length = Int(buffer[readIndex + 2]) << 8 | Int(buffer[readIndex + 3])
                guard available >= 4 + length else { break }
                let packet = Array(buffer[(readIndex + 4)..<(readIndex + 4 + length)])
                readIndex += 4 + length
                onPacket?(channel, packet)
            } else if first == 0x52 {                   // "R": the start of "RTSP/1.0 200 OK".
                guard let end = indexOfHeaderEnd(from: readIndex) else {
                    if available > 64 * 1024 { readIndex += 1 }   // Not a response. Skip a byte.
                    break
                }
                let head = String(decoding: buffer[readIndex..<end], as: UTF8.self)
                var lines = head.components(separatedBy: "\r\n")
                let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2)
                guard statusLine.count >= 2, statusLine[0].hasPrefix("RTSP/"), let code = Int(statusLine[1]) else {
                    readIndex += 1
                    continue
                }
                var headers: [String: String] = [:]
                for line in lines {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                let bodyLength = Int(headers["content-length"] ?? "0") ?? 0
                let bodyStart = end + 4
                guard buffer.count >= bodyStart + bodyLength else { break }
                let body = Array(buffer[bodyStart..<(bodyStart + bodyLength)])
                readIndex = bodyStart + bodyLength
                let response = Response(status: code, reason: statusLine.count > 2 ? String(statusLine[2]) : "",
                                        headers: headers, body: body)
                if let id = Int(headers["cseq"] ?? ""), let callback = pending.removeValue(forKey: id) {
                    callback(.success(response))
                }
            } else {
                readIndex += 1                          // Out of step. Find the next frame.
            }
        }
        if readIndex == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex > 128 * 1024 {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
    }

    private func indexOfHeaderEnd(from start: Int) -> Int? {
        let limit = buffer.count - 4
        guard limit >= start else { return nil }
        var i = start
        while i <= limit {
            if buffer[i] == 13, buffer[i + 1] == 10, buffer[i + 2] == 13, buffer[i + 3] == 10 { return i }
            i += 1
        }
        return nil
    }
}
