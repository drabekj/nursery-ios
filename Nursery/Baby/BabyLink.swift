import Foundation
import Network
import UIKit

/// The parent's side of the link to the iPhone at the baby: it finds the phones with Bonjour.
@MainActor
final class BabyBrowser: ObservableObject {
    @Published private(set) var names: [String] = []
    @Published private(set) var failed: String?
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        if MonitorEngine.isDemo { names = ["Pokojíček"]; return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: BabyService.type, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                if case .service(let name, _, _, _) = result.endpoint { return name }
                return nil
            }
            Task { @MainActor in self?.names = Array(Set(names)).sorted() }
        }
        browser.stateUpdateHandler = { [weak self] state in
            let message: String?
            switch state {
            case .failed(let error), .waiting(let error):
                message = "Hledání nefunguje (\(error.localizedDescription)). Povolte Chůvičce místní síť v Nastavení iPhonu."
            default:
                message = nil
            }
            Task { @MainActor in self?.failed = message }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

/// One photo from the iPhone at the baby, over the same connection type as the stream.
enum BabyLink {
    static func endpoint(name: String) -> NWEndpoint {
        .service(name: name, type: BabyService.type, domain: "local.", interface: nil)
    }

    static func frame(name: String, code: String) async -> UIImage? {
        guard let data = await fetch(endpoint: endpoint(name: name), path: "/\(code)/frame.jpeg") else { return nil }
        return UIImage(data: data)
    }

    /// A plain HTTP/1.1 GET. The server closes the connection after the answer.
    private static func fetch(endpoint: NWEndpoint, path: String) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            let request = Fetch(endpoint: endpoint, path: path) { cont.resume(returning: $0) }
            request.start()
        }
    }
}

/// One HTTP GET. It finishes one time: with the body, or nil after an error or 8 s.
private final class Fetch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "nursery.baby.fetch")
    private let connection: NWConnection
    private let path: String
    private let done: (Data?) -> Void
    private var buffer = Data()
    private var finished = false

    init(endpoint: NWEndpoint, path: String, done: @escaping (Data?) -> Void) {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        connection = NWConnection(to: endpoint, using: params)
        self.path = path
        self.done = done
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                let head = "GET \(path) HTTP/1.1\r\nHost: chuvicka\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
                receive()
            case .failed, .waiting:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 8) { [self] in finish(nil) }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, complete, error in
            if let data { buffer.append(data) }
            if let body = body() { finish(body); return }
            if complete || error != nil { finish(nil); return }
            receive()
        }
    }

    /// The body when the whole answer is here, from the Content-Length.
    private func body() -> Data? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        guard head.hasPrefix("HTTP/1.1 200") else { return nil }
        let length = head.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? -1
        let bodyStart = end.upperBound
        guard length >= 0, buffer.count - bodyStart >= length else { return nil }
        return Data(buffer[bodyStart..<(bodyStart + length)])
    }

    private func finish(_ data: Data?) {
        guard !finished else { return }
        finished = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        done(data)
    }
}
