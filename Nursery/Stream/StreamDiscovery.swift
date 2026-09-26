import Foundation

/// go2rtc knows its streams, so the app learns the detail and the everyday stream itself:
/// the stream with the most pixels is the detail (main) stream, the one with the fewest the
/// everyday (sub) stream. It runs in the test step of the guide. When nothing usable comes back,
/// the current names stay (`HomeDefaults`, or what the user typed).
enum StreamDiscovery {
    /// At most this many streams are asked, all at the same time.
    private static let limit = 8

    private struct Probe: Sendable {
        let name: String
        let width: Int
        let height: Int
        var pixels: Int { width * height }
        var text: String { "\(name) \(width)×\(height)" }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    @MainActor static func run(settings: Settings) async {
        let host = settings.serverHost
        guard !host.isEmpty else { return }
        let names: [String]
        do {
            names = try await Self.streamNames(host: host)
        } catch {
            Log.shared.add("streams not read from go2rtc: \(error.localizedDescription)")
            return
        }
        // The current names first, so the limit never drops them. A name that is not safe in a
        // URL path cannot be played, so it is not asked.
        let current = [settings.streamMain, settings.streamSmall]
        func rank(_ name: String) -> Int { current.contains(name) ? 0 : 1 }
        let candidates = Array(names
            .filter { !$0.isEmpty && $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) == $0 }
            .sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0 < $1 }
            .prefix(limit))
        guard !candidates.isEmpty else {
            Log.shared.add("streams: go2rtc has none, keeping \(settings.streamMain), \(settings.streamSmall)")
            return
        }
        let found = await withTaskGroup(of: Probe?.self, returning: [String: Probe].self) { group in
            for name in candidates {
                group.addTask { await Self.probe(host: host, stream: name) }
            }
            var all: [String: Probe] = [:]
            for await p in group { if let p { all[p.name] = p } }
            return all
        }
        // In the order of the candidates, so a tie always picks the same stream.
        let usable = candidates.compactMap { found[$0] }
        let list = candidates.map { found[$0]?.text ?? "\($0) –" }.joined(separator: ", ")
        guard let detail = usable.max(by: { $0.pixels < $1.pixels }),
              let smallest = usable.min(by: { $0.pixels < $1.pixels }) else {
            Log.shared.add("streams: \(list) → no H.264 picture, keeping \(settings.streamMain), \(settings.streamSmall)")
            return
        }
        // Streams of the same size: one stream for both, so the app never switches for nothing.
        let everyday = smallest.pixels == detail.pixels ? detail : smallest
        Log.shared.add("streams: \(list) → detail \(detail.name), everyday \(everyday.name)")
        // Set only a change: each set redraws every view that watches the settings.
        if settings.streamMain != detail.name { settings.streamMain = detail.name }
        if settings.streamSmall != everyday.name { settings.streamSmall = everyday.name }
    }

    /// GET /api/streams: a JSON object, and its keys are the stream names.
    private static func streamNames(host: String) async throws -> [String] {
        guard let url = URL(string: "http://\(host):\(Go2rtc.apiPort)/api/streams") else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return Array(object.keys)
    }

    /// The picture size of one stream: from the SPS in the SDP, else from the first SPS in the stream.
    private static func probe(host: String, stream: String) async -> Probe? {
        let url = "rtsp://\(host):\(Go2rtc.rtspPort)/\(stream)"
        guard let client = try? RTSPClient(url: url) else { return nil }
        let timer = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { client.stop() }
        }
        let tracks = try? await client.describe()
        timer.cancel()
        guard let video = tracks?.first(where: { $0.kind == .video && $0.codec == "H264" }) else { return nil }
        var sps = video.h264ParameterSets?.sps
        if sps == nil { sps = await Self.inBandSPS(url: url) }
        guard let sps, let size = H264SPS.size(sps) else { return nil }
        return Probe(name: stream, width: size.width, height: size.height)
    }

    /// The SDP has no SPS: play the stream until the first SPS comes, for 4 s at most.
    private static func inBandSPS(url: String) async -> [UInt8]? {
        guard let client = try? RTSPClient(url: url) else { return nil }
        let found = Found()
        let timer = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { client.stop() }
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { (cont: CheckedContinuation<[UInt8]?, Never>) in
            // It runs one time, for any end: the SPS came, the time is up, or an error.
            client.onClose = { _ in cont.resume(returning: found.sps) }
            Task {
                do {
                    _ = try await client.start { tracks in
                        guard let video = tracks.first(where: { $0.sdp.kind == .video && $0.sdp.codec == "H264" })?.channel else {
                            client.stop()
                            return
                        }
                        let depacketizer = H264Depacketizer()
                        client.onPacket = { channel, bytes in
                            guard channel == video, let packet = RTPPacket(bytes) else { return }
                            _ = depacketizer.push(packet)
                            if let sps = depacketizer.sps, found.sps == nil {
                                found.sps = sps
                                client.stop()
                            }
                        }
                    }
                } catch {
                    client.stop()
                }
            }
        }
    }

    /// The SPS from the RTSP queue.
    private final class Found: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [UInt8]?
        var sps: [UInt8]? {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }
}
