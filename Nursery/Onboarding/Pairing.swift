@preconcurrency import AVFoundation
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// The pairing link in the QR code of the phone at the baby. The Android app makes the same:
/// chuvicka://pair?n=<name>&c=<code>&a=<ip:port,ip:port>
/// The system camera also opens it, so a parent can pair with the camera app too.
struct PairLink: Equatable {
    let name: String
    let code: String
    let addresses: [String]

    init(name: String, code: String, addresses: [String]) {
        self.name = name
        self.code = code
        self.addresses = addresses
    }

    init?(url: URL) {
        guard url.scheme == "chuvicka", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let value = { (key: String) in items.first { $0.name == key }?.value ?? "" }
        let code = value("c").filter(\.isNumber)
        guard !value("n").isEmpty, code.count == 6 else { return nil }
        self.name = value("n")
        self.code = code
        self.addresses = value("a").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var url: URL {
        var c = URLComponents()
        c.scheme = "chuvicka"
        c.host = "pair"
        c.queryItems = [.init(name: "n", value: name), .init(name: "c", value: code),
                        .init(name: "a", value: addresses.joined(separator: ","))]
        // URLComponents leaves "+" as it is, and Android reads it as a space. Encode it.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    /// The parent keeps it: the name for Bonjour at home, the addresses for the time away.
    @MainActor func apply(to settings: Settings) {
        settings.babyCode = code
        settings.babyName = name
        if !addresses.isEmpty { settings.babyAddresses = addresses }
        settings.source = .phone
        Log.shared.add("paired with \(name) by QR code")
    }
}

/// A QR code, sharp at any size.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityLabel("QR kód pro spárování")
        }
    }

    static func image(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// The camera finds a pairing QR code. It calls `found` one time.
struct QRScanner: UIViewControllerRepresentable {
    let found: (PairLink) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.found = found
        return c
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var found: ((PairLink) -> Void)?
        private let session = AVCaptureSession()
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            view.layer.sublayers?.first?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let text = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
                  let url = URL(string: text), let link = PairLink(url: url) else { return }
            done = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            found?(link)
        }
    }
}

/// A short live test of the chosen source: it connects, and counts the picture and the sound.
@MainActor
final class ConnectionTest: ObservableObject {
    enum Step: Equatable { case waiting, ok, failed(String) }
    @Published private(set) var connection: Step = .waiting
    @Published private(set) var picture: Step = .waiting
    @Published private(set) var sound: Step = .waiting
    @Published private(set) var running = false
    private var client: RTSPClient?

    var passed: Bool { connection == .ok && (picture == .ok || sound == .ok) }

    func run(settings: Settings, wantsPicture: Bool) {
        client?.stop()
        connection = .waiting; picture = .waiting; sound = .waiting
        running = true
        if MonitorEngine.isDemo {
            connection = .ok; picture = .ok; sound = .ok; running = false
            return
        }
        Task {
            // The phone at the baby: its reported address first, then Bonjour.
            var endpoint = settings.babyEndpoint
            if settings.source == .phone {
                for address in settings.babyAddresses {
                    guard let a = Reach.split(address), await Reach.canConnect(host: a.host, port: a.port) else { continue }
                    settings.babyDirect = address
                    endpoint = settings.babyEndpoint
                    break
                }
            }
            // go2rtc: learn the detail and the everyday stream first. Then the test plays the main stream.
            if settings.source == .camera && settings.cameraKind == .go2rtc {
                await StreamDiscovery.run(settings: settings)
            }
            let url = settings.streamURL(audioOnly: false, small: false)
            guard let client = try? RTSPClient(url: url, endpoint: endpoint) else {
                finish(connection: .failed("Adresa není platná."))
                return
            }
            self.client = client
            let counts = Counts()
            do {
                let tracks = try await client.start { tracks in
                    let video = tracks.first { $0.sdp.kind == .video }?.channel
                    let audio = tracks.first { $0.sdp.kind == .audio }?.channel
                    client.onPacket = { channel, _ in
                        if channel == video { counts.add(video: true) } else if channel == audio { counts.add(video: false) }
                    }
                }
                connection = .ok
                if settings.source == .phone { settings.babyAddresses = client.serverAddresses.isEmpty ? settings.babyAddresses : client.serverAddresses }
                let hasAudio = tracks.contains { $0.sdp.kind == .audio }
                try? await Task.sleep(for: .seconds(4))
                let (v, a) = counts.values
                picture = v > 0 ? .ok : .failed(wantsPicture ? "Obraz nepřišel." : "Jen zvuk.")
                sound = a > 0 ? .ok : .failed(hasAudio ? "Zvuk nepřišel. Je v kameře zapnutý mikrofon?"
                                                        : "Kamera posílá zvuk ve formátu, kterému Chůvička nerozumí. V aplikaci kamery přepněte zvuk na G.711.")
            } catch {
                connection = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                picture = .failed(""); sound = .failed("")
            }
            client.stop()
            self.client = nil
            running = false
        }
    }

    private func finish(connection c: Step) {
        connection = c; picture = .failed(""); sound = .failed(""); running = false
    }

    /// Packet counts from the RTSP queue.
    private final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var v = 0, a = 0
        func add(video: Bool) { lock.lock(); if video { v += 1 } else { a += 1 }; lock.unlock() }
        var values: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (v, a) }
    }
}
