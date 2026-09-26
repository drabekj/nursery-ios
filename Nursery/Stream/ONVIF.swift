import CryptoKit
import Foundation

/// ONVIF pan and tilt: SOAP 1.2 over HTTP, with a WS-Security UsernameToken (PasswordDigest).
/// The camera account is the same as for RTSP. The functions here are pure, for the tests;
/// `ONVIFClient` sends them.
enum ONVIF {
    static let getProfilesBody = #"<trt:GetProfiles xmlns:trt="http://www.onvif.org/ver10/media/wsdl"/>"#

    /// The WS-Security header. digest = base64(SHA1(nonce + created + password)).
    static func securityHeader(user: String, password: String, nonce: [UInt8], created: String) -> String {
        var data = Data(nonce)
        data.append(Data(created.utf8))
        data.append(Data(password.utf8))
        let digest = Data(Insecure.SHA1.hash(data: data)).base64EncodedString()
        let nonce64 = Data(nonce).base64EncodedString()
        return #"<wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">"#
            + "<wsse:UsernameToken><wsse:Username>\(escape(user))</wsse:Username>"
            + #"<wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">"#
            + "\(digest)</wsse:Password><wsse:Nonce>\(nonce64)</wsse:Nonce><wsu:Created>\(created)</wsu:Created>"
            + "</wsse:UsernameToken></wsse:Security>"
    }

    static func envelope(body: String, security: String) -> String {
        #"<?xml version="1.0"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Header>"#
            + security + "</s:Header><s:Body>" + body + "</s:Body></s:Envelope>"
    }

    /// Turn at this speed until Stop. x: left −, right +. y: down −, up +.
    static func continuousMoveBody(token: String, x: Float, y: Float) -> String {
        let vx = String(format: "%.1f", Double(x))
        let vy = String(format: "%.1f", Double(y))
        return #"<tptz:ContinuousMove xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema">"#
            + "<tptz:ProfileToken>\(escape(token))</tptz:ProfileToken><tptz:Velocity>"
            + "<tt:PanTilt x=\"\(vx)\" y=\"\(vy)\"/>"
            + "</tptz:Velocity></tptz:ContinuousMove>"
    }

    static func stopBody(token: String) -> String {
        #"<tptz:Stop xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema">"#
            + "<tptz:ProfileToken>\(escape(token))</tptz:ProfileToken><tptz:PanTilt>true</tptz:PanTilt></tptz:Stop>"
    }

    private static let profilePattern = try! NSRegularExpression(
        pattern: #"<(?:[A-Za-z0-9_.-]+:)?Profiles\b([^>]*)>(.*?)</(?:[A-Za-z0-9_.-]+:)?Profiles\s*>"#,
        options: [.dotMatchesLineSeparators])
    private static let tokenPattern = try! NSRegularExpression(pattern: #"\btoken\s*=\s*(?:"([^"]*)"|'([^']*)')"#)

    /// The token of the first profile that can turn (it has a PTZConfiguration), from the
    /// GetProfiles answer. The token is not the first attribute (`fixed="true" token="profile_1"`).
    static func ptzProfileToken(in xml: String) -> String? {
        let ns = xml as NSString
        for m in profilePattern.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let body = ns.substring(with: m.range(at: 2))
            guard body.contains("PTZConfiguration") else { continue }
            let attributes = ns.substring(with: m.range(at: 1))
            let a = attributes as NSString
            guard let t = tokenPattern.firstMatch(in: attributes, range: NSRange(location: 0, length: a.length)) else { continue }
            let value = t.range(at: 1).location != NSNotFound ? a.substring(with: t.range(at: 1)) : a.substring(with: t.range(at: 2))
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// The time for `Created`: UTC, with no fraction.
    static func createdNow() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: Date())
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// It turns one camera over ONVIF. It lives on the main actor: the state is small, and each
/// request waits off the main thread in URLSession.
@MainActor
final class ONVIFClient {
    let host: String
    let port: UInt16
    let user: String
    private let password: String
    /// The PTZ profile, in memory only. A new client asks again.
    private var token: String?
    /// One step at a time: a held arrow repeats faster than a step ends.
    private var stepping = false
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    init(host: String, port: UInt16, user: String, password: String) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
    }

    /// GetProfiles, then the token of the first profile that can turn. Nil: the camera cannot turn,
    /// or it does not answer.
    func loadPTZProfile() async -> String? {
        if let token { return token }
        guard let xml = await call(ONVIF.getProfilesBody, what: "GetProfiles") else { return nil }
        token = ONVIF.ptzProfileToken(in: xml)
        if token == nil { Log.shared.add("ONVIF: no PTZ profile on \(host):\(port)") }
        return token
    }

    func move(x: Float, y: Float) async -> Bool {
        guard let token = await loadPTZProfile() else { return false }
        return await call(ONVIF.continuousMoveBody(token: token, x: x, y: y), what: "ContinuousMove") != nil
    }

    func stop() async -> Bool {
        guard let token = await loadPTZProfile() else { return false }
        return await call(ONVIF.stopBody(token: token), what: "Stop") != nil
    }

    /// One step: turn, wait, stop. Stop also after a failed move, so the camera never keeps turning.
    /// A step that comes while one runs is skipped: the camera still turns from the running one.
    func step(x: Float, y: Float, seconds: Double = 0.6) async -> Bool {
        guard !stepping else { return true }
        stepping = true
        defer { stepping = false }
        let moved = await move(x: x, y: y)
        if moved { try? await Task.sleep(for: .seconds(seconds)) }
        let stopped = await stop()
        return moved && stopped
    }

    /// One SOAP request. The answer text on HTTP 200, else nil. The log line has no password.
    private func call(_ body: String, what: String) async -> String? {
        guard let url = URL(string: "http://\(host):\(port)/onvif/service") else { return nil }
        let nonce = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let security = ONVIF.securityHeader(user: user, password: password, nonce: nonce, created: ONVIF.createdNow())
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/soap+xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(ONVIF.envelope(body: body, security: security).utf8)
        do {
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                // 400 with a SOAP Fault: usually a wrong user or password.
                Log.shared.add("ONVIF \(what) on \(host):\(port): HTTP \(status)")
                return nil
            }
            return String(decoding: data, as: UTF8.self)
        } catch {
            Log.shared.add("ONVIF \(what) on \(host):\(port) failed: \(error.localizedDescription)")
            return nil
        }
    }
}
