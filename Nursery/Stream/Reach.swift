import Foundation
import Network

/// The ways to the stream from outside the home.
///
/// At home, the app connects directly: to the Pi's LAN address, or to the phone at the baby that
/// Bonjour finds. Away from home, the LAN address does not answer, and Bonjour does not work
/// over a VPN. Then the app uses Tailscale: the Pi's Tailscale address, or the addresses that
/// the phone at the baby reported at home. The phone that watches must have Tailscale on.
enum Reach {
    /// Tailscale gives each device an address in 100.64.0.0/10.
    static func isTailscale(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// A TCP connection test. It answers in `timeout` at most: a quick "is home here?".
    static func canConnect(host: String, port: UInt16, timeout: TimeInterval = 1.2) async -> Bool {
        guard let p = NWEndpoint.Port(rawValue: port) else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            let once = Once()
            let queue = DispatchQueue(label: "nursery.reach")
            let finish: @Sendable (Bool) -> Void = { ok in
                guard once.claim() else { return }
                conn.stateUpdateHandler = nil
                conn.cancel()
                cont.resume(returning: ok)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting: finish(false)
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// "192.168.0.50:8555" or "100.101.102.103:8555" to its parts.
    static func split(_ address: String) -> (host: String, port: UInt16)? {
        guard let colon = address.lastIndex(of: ":"), let port = UInt16(address[address.index(after: colon)...]) else { return nil }
        return (String(address[..<colon]), port)
    }

    /// This phone's IPv4 addresses, the Tailscale one first. The phone at the baby reports them,
    /// so a parent can reach it from outside the home.
    static func localAddresses() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(a.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") { continue }          // No real address.
            if !result.contains(ip) { result.append(ip) }
        }
        return result.sorted { isTailscale($0) && !isTailscale($1) }
    }
}

/// A flag that one caller can claim, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
