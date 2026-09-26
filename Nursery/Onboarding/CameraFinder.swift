import Foundation
import Network
import SwiftUI

/// It finds cameras (and go2rtc servers) on the home Wi-Fi, so nobody has to look up an address.
///
/// It tries a TCP connection to one port on each address of the phone's home network (/24):
/// 554 is the RTSP port of nearly every IP camera, 1984 is the go2rtc API. A camera that answers
/// then gets one RTSP request. Its answer (the Server header, or the realm of the login) often
/// names the brand. Not ONVIF discovery: that needs multicast, and iOS allows multicast only
/// with a paid developer account.
enum CameraFinder {
    struct Found: Identifiable, Hashable {
        let host: String
        /// The brand, when the answer names one.
        let brand: CameraBrand?
        /// What the device calls itself, for the list, for example "TP-LINK IP-Camera".
        let label: String?
        var id: String { host }
    }

    /// All devices that answer on `port`, in about 3 s.
    static func scan(port: UInt16) async -> [Found] {
        guard let (own, prefix) = homeNetwork() else { return [] }
        let hosts = (1...254).map { "\(prefix).\($0)" }.filter { $0 != own }
        var open: [String] = []
        await withTaskGroup(of: String?.self) { group in
            // At most 48 tries at a time: fast, and gentle with the router.
            var next = 0
            while next < min(48, hosts.count) {
                let host = hosts[next]
                next += 1
                group.addTask { await Reach.canConnect(host: host, port: port, timeout: 0.8) ? host : nil }
            }
            while let result = await group.next() {
                if let result { open.append(result) }
                if next < hosts.count {
                    let host = hosts[next]
                    next += 1
                    group.addTask { await Reach.canConnect(host: host, port: port, timeout: 0.8) ? host : nil }
                }
            }
        }
        var found: [Found] = []
        for host in open.sorted(by: { lastPart($0) < lastPart($1) }) {
            let answer = port == 554 ? await rtspAnswer(host: host) : nil
            found.append(Found(host: host, brand: answer.flatMap(brand(in:)), label: answer.flatMap(label(in:))))
        }
        Log.shared.add("camera search on port \(port): \(found.count) found")
        return found
    }

    /// The Wi-Fi address and its first three parts ("192.168.0"). Wi-Fi (en0) first,
    /// else any private address. Nil with no home network.
    static func homeNetwork() -> (own: String, prefix: String)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var wifi: String?
        var other: String?
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard isPrivate(ip) else { continue }
            if String(cString: a.pointee.ifa_name) == "en0" { wifi = ip } else if other == nil { other = ip }
        }
        guard let ip = wifi ?? other else { return nil }
        return (ip, ip.split(separator: ".").prefix(3).joined(separator: "."))
    }

    /// 10/8, 172.16/12 and 192.168/16: the addresses of home networks.
    static func isPrivate(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
    }

    private static func lastPart(_ ip: String) -> Int { Int(ip.split(separator: ".").last ?? "") ?? 0 }

    // MARK: Who is it

    /// The brand in an RTSP answer, from its Server header or the realm of the login.
    static func brand(in answer: String) -> CameraBrand? {
        let a = answer.lowercased()
        if a.contains("tp-link") || a.contains("tapo") { return .tapo }
        if a.contains("hikvision") { return .hikvision }
        if a.contains("dahua") || a.contains("login to") { return .dahua }      // Dahua: realm="Login to <serial>".
        if a.contains("reolink") { return .reolink }
        return nil
    }

    /// A short name for the list: the realm of the login, else the Server header.
    static func label(in answer: String) -> String? {
        if let brand = brand(in: answer) { return brand.title }
        let lines = answer.components(separatedBy: "\r\n")
        let realm = lines.first { $0.lowercased().hasPrefix("www-authenticate:") }.flatMap { line -> String? in
            guard let r = line.range(of: "realm=\"") else { return nil }
            return line[r.upperBound...].split(separator: "\"").first.map(String.init)
        }
        let server = lines.first { $0.lowercased().hasPrefix("server:") }
            .map { $0.dropFirst("server:".count).trimmingCharacters(in: .whitespaces) }
        guard let name = realm ?? server, !name.isEmpty else { return nil }
        return String(name.prefix(32))
    }

    /// One DESCRIBE with no login. Cameras answer 401 with the realm, or 200/404 with a Server header.
    private static func rtspAnswer(host: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: 554, using: .tcp)
            let once = Once()
            let queue = DispatchQueue(label: "nursery.finder")
            let finish: @Sendable (String?) -> Void = { text in
                guard once.claim() else { return }
                conn.stateUpdateHandler = nil
                conn.cancel()
                cont.resume(returning: text)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let request = "DESCRIBE rtsp://\(host):554/ RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: Chuvicka\r\n\r\n"
                    conn.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                        finish(data.map { String(decoding: $0, as: UTF8.self) })
                    }
                case .failed, .waiting: finish(nil)
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1.5) { finish(nil) }
        }
    }
}

/// "Najít kameru": it searches the home Wi-Fi and fills the address with one tap.
/// With the address still empty it searches at once, and one find fills the address by itself.
struct FinderSection: View {
    let port: UInt16
    /// "kameru" or "server", for "Hledám kameru…".
    let what: String
    /// What to do when nothing answers.
    let hint: String
    @Binding var host: String

    private enum Phase { case idle, searching, done([CameraFinder.Found]) }
    @State private var phase = Phase.idle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch phase {
            case .idle:
                Button { Task { await search() } } label: {
                    Label("Najít \(what) v domácí síti", systemImage: "wifi")
                }
                .font(.subheadline.weight(.semibold))
                .tint(Theme.accent)
            case .searching:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Hledám \(what) v domácí síti…").foregroundStyle(.secondary)
                }
                .font(.subheadline)
            case .done(let list) where list.isEmpty:
                Text(hint).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Hledat znovu") { Task { await search() } }
                    .font(.subheadline.weight(.semibold))
                    .tint(Theme.accent)
            case .done(let list):
                Text(list.count == 1 ? "Našli jsme:" : "Vyberte ji ze seznamu:")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(list) { item in
                    Button {
                        Haptics.tap()
                        host = item.host
                    } label: {
                        HStack {
                            Text(item.label ?? "Zařízení").foregroundStyle(.primary)
                            Spacer()
                            Text(item.host).monospacedDigit().foregroundStyle(.secondary)
                            if host.trimmingCharacters(in: .whitespaces) == item.host {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                            }
                        }
                        .padding(14)
                        .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.label ?? "Zařízení"), \(item.host)")
                }
                Button("Hledat znovu") { Task { await search() } }
                    .font(.footnote.weight(.semibold))
                    .tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            if host.trimmingCharacters(in: .whitespaces).isEmpty, !MonitorEngine.isDemo { await search() }
        }
    }

    private func search() async {
        phase = .searching
        let list = await CameraFinder.scan(port: port)
        phase = .done(list)
        if list.count == 1, host.trimmingCharacters(in: .whitespaces).isEmpty { host = list[0].host }
    }
}
