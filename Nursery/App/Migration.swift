import Foundation

/// A phone set up with the go2rtc server moves to the camera read directly, once.
///
/// go2rtc knows the camera's own RTSP address with its login (`/api/streams`, else `/api/config`).
/// The app takes it from there, so nobody types anything. The server settings (host, streams,
/// remote host) stay as they were: the guide can go back to the server at any time.
enum ServerMigration {
    struct Result: Equatable {
        let host: String
        let port: Int
        let user: String
        let password: String
        let mainPath: String
        let smallPath: String?
        let brand: CameraBrand
    }

    /// Set after one run that reached the server, with a result or without.
    static let doneKey = "directMigrated"

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// It runs at launch, before the monitor starts. True when the app now reads the camera directly.
    @MainActor static func run(settings: Settings) async -> Bool {
        let defaults = UserDefaults.standard
        guard !MonitorEngine.isDemo, settings.cameraKind == .go2rtc, settings.source == .camera,
              !defaults.bool(forKey: doneKey) else { return false }
        let host = settings.trimmedHost
        guard !host.isEmpty else { return false }
        // Away from home the LAN address does not answer: try again at the next launch,
        // and do not hold up the start for long.
        guard await Reach.canConnect(host: host, port: Go2rtc.apiPort, timeout: 0.8) else { return false }
        let main = settings.streamMain
        let small = settings.streamSmall
        var found: Result?
        if let data = await get(host: host, path: "api/streams") {
            found = parse(streamsJSON: data, main: main, small: small)
        }
        if found == nil, let data = await get(host: host, path: "api/config") {
            found = parse(configYAML: String(decoding: data, as: UTF8.self), main: main, small: small)
        }
        defaults.set(true, forKey: doneKey)
        guard let r = found else {
            Log.shared.add("migration: the server gives no camera address, staying with the server")
            return false
        }
        // A brand only when its path is the one the app would use. Else a full address ("Jiná kamera").
        let known = r.brand != .other && r.mainPath.lowercased() == r.brand.paths.main.lowercased()
        let brand: CameraBrand = known ? r.brand : .other
        settings.rtspBrand = brand
        settings.rtspHost = r.host
        settings.rtspPort = r.port
        settings.rtspUser = r.user
        CameraSecret.password = r.password
        if brand == .other { settings.rtspCustom = "\(r.host):\(r.port)/\(r.mainPath)" }
        settings.cameraKind = .rtsp
        Log.shared.add("migrated to the direct camera \(r.host) (\(brand.rawValue))")
        return true
    }

    private static func get(host: String, path: String) async -> Data? {
        guard let url = URL(string: "http://\(host):\(Go2rtc.apiPort)/\(path)") else { return nil }
        guard let answer = try? await session.data(from: url),
              (answer.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return answer.0
    }

    // MARK: Parsing (pure, for the tests)

    /// `/api/streams`: `{"nursery":{"producers":[{"url":"rtsp://…"}]}, …}`.
    static func parse(streamsJSON: Data, main: String, small: String) -> Result? {
        guard let object = (try? JSONSerialization.jsonObject(with: streamsJSON)) as? [String: Any] else { return nil }
        func url(of name: String) -> String? {
            guard let stream = object[name] as? [String: Any],
                  let producers = stream["producers"] as? [[String: Any]] else { return nil }
            return producers.compactMap { $0["url"] as? String }.first { $0.lowercased().hasPrefix("rtsp://") }
        }
        return result(main: url(of: main), small: url(of: small))
    }

    /// `/api/config`: the YAML file. Only the `streams:` block is read, and in it the first
    /// `- rtsp://…` item of each stream (or `name: rtsp://…` on one line).
    static func parse(configYAML: String, main: String, small: String) -> Result? {
        let block = streamsBlock(configYAML)
        return result(main: yamlURL(of: main, in: block), small: yamlURL(of: small, in: block))
    }

    /// The lines under the top-level `streams:` key, with no comments and no empty lines.
    private static func streamsBlock(_ yaml: String) -> [String] {
        var inside = false
        var block: [String] = []
        for raw in yaml.components(separatedBy: .newlines) {
            let line = uncommented(raw)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let topLevel = !(line.first?.isWhitespace ?? false)
            if topLevel {
                if inside { break }
                inside = line.trimmingCharacters(in: .whitespaces) == "streams:"
                continue
            }
            if inside { block.append(line) }
        }
        return block
    }

    /// A YAML comment starts with "#" after a space. "rtsp://…#backchannel=0" is not a comment.
    private static func uncommented(_ line: String) -> String {
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { return "" }
        if let r = line.range(of: " #") { return String(line[..<r.lowerBound]) }
        return line
    }

    private static func yamlURL(of name: String, in block: [String]) -> String? {
        guard !name.isEmpty else { return nil }
        var nameIndent: Int?
        for line in block {
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            let text = line.trimmingCharacters(in: .whitespaces)
            if let n = nameIndent {
                // The next stream starts: this one has no RTSP source.
                if indent < n || (indent == n && !text.hasPrefix("-")) { return nil }
                if text.hasPrefix("-") {
                    let value = unquoted(String(text.dropFirst()))
                    if value.lowercased().hasPrefix("rtsp://") { return value }
                }
                continue
            }
            for key in [name, "\"\(name)\"", "'\(name)'"] where text.hasPrefix(key + ":") {
                let rest = unquoted(String(text.dropFirst(key.count + 1)))
                if rest.isEmpty {
                    nameIndent = indent
                } else if rest.lowercased().hasPrefix("rtsp://") {
                    return rest
                }
            }
        }
        return nil
    }

    private static func unquoted(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, let first = t.first, first == t.last, first == "\"" || first == "'" {
            return String(t.dropFirst().dropLast())
        }
        return t
    }

    private static func result(main: String?, small: String?) -> Result? {
        guard let main, let m = split(main) else { return nil }
        let s = small.flatMap { split($0) }
        // The sub stream counts only when it is the same camera.
        let smallPath = (s?.host == m.host && s?.port == m.port) ? s?.path : nil
        return Result(host: m.host, port: m.port, user: m.user, password: m.password,
                      mainPath: m.path, smallPath: smallPath, brand: brand(path: m.path))
    }

    /// "rtsp://u%40x:p%3Ass@192.168.0.197:554/stream1" to its parts, with the login decoded.
    /// A loopback address is go2rtc reading itself, not a camera.
    private static func split(_ url: String) -> (host: String, port: Int, user: String, password: String, path: String)? {
        guard let u = URLComponents(string: url), u.scheme?.lowercased() == "rtsp",
              let host = u.host, !host.isEmpty,
              host != "localhost", !host.hasPrefix("127."), host != "::1" else { return nil }
        var path = u.percentEncodedPath
        if path.hasPrefix("/") { path.removeFirst() }
        if let query = u.percentEncodedQuery, !query.isEmpty { path += "?" + query }
        let user = u.percentEncodedUser.map { $0.removingPercentEncoding ?? $0 } ?? ""
        let password = u.percentEncodedPassword.map { $0.removingPercentEncoding ?? $0 } ?? ""
        return (host, u.port ?? 554, user, password, path)
    }

    /// The brand from the stream path.
    static func brand(path: String) -> CameraBrand {
        let p = path.lowercased()
        if p.hasPrefix("stream1") || p.hasPrefix("stream2") { return .tapo }
        if p.hasPrefix("streaming/channels") { return .hikvision }
        if p.hasPrefix("cam/realmonitor") { return .dahua }
        if p.hasPrefix("h264preview") { return .reolink }
        return .other
    }
}
