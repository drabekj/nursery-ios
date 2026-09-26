import SwiftUI

/// "Mimo domov": the Tailscale checklist, with a live check for each side.
/// The only screen that names Tailscale. The switch between home and away is automatic, in the engine.
struct RemoteAccessView: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var engine: MonitorEngine
    @EnvironmentObject private var camera: CameraControl
    @State private var hereOK = false
    @State private var otherOK = false
    @State private var remote = ""

    private var directCamera: Bool { settings.source == .camera && settings.cameraKind == .rtsp }

    var body: some View {
        Form {
            Section {
                Text("Chcete se dívat i mimo domov, třeba z práce? Stačí bezplatná aplikace Tailscale. Bezpečně a šifrovaně propojí vaše telefony, obraz nejde přes cizí server. Nastavíte ji jednou.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if directCamera {
                // A camera read directly: away from home the phone reaches the camera's home address
                // through a Tailscale subnet route (set up on a computer or router at home).
                Section {
                    hereRow
                    checklistRow("Domácí síť přes Tailscale", ok: otherOK,
                                 help: "Pro pokročilé: na počítači nebo routeru doma zapněte v Tailscale sdílení domácí sítě (subnet route) pro adresu kamery. Pak Chůvička mimo domov použije stejnou adresu kamery jako doma.") {
                        EmptyView()
                    }
                } footer: {
                    Text("Každý bod se zaškrtne sám, jakmile je hotový.\nOvěří se samo, až budete mimo domov.")
                }
            } else {
                Section {
                    hereRow
                    other
                } footer: {
                    Text("Každý bod se zaškrtne sám, jakmile je hotový.\nDoma se Chůvička připojuje přímo. Tailscale použije sama, až budete pryč.")
                }
            }
        }
        .navigationTitle("Mimo domov")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { remote = settings.remoteHost }
        .onDisappear(perform: applyRemote)
        .task {
            while !Task.isCancelled {
                hereOK = MonitorEngine.isDemo || Reach.localAddresses().contains(where: Reach.isTailscale)
                otherOK = await otherCheck()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var hereRow: some View {
        checklistRow("Tailscale v tomto telefonu", ok: hereOK,
                     help: "Nainstalujte Tailscale, přihlaste se a zapněte ho.") {
            if !hereOK {
                Link("Stáhnout Tailscale", destination: URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!)
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    @ViewBuilder private var other: some View {
        if settings.source == .phone {
            checklistRow("Tailscale v telefonu u miminka", ok: otherOK,
                         help: "Nainstalujte Tailscale i na telefon u miminka, přihlaste se stejným účtem a jednou se k němu připojte doma.") {
                if let address = babyTailscale {
                    Text(address).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        } else {
            checklistRow("Server přes Tailscale", ok: otherOK, help: "Zadejte název nebo adresu serveru v Tailscale.") {
                TextField("například raspberrypi", text: $remote)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(applyRemote)
            }
        }
    }

    /// The Tailscale address of the phone at the baby, known after one connection at home.
    private var babyTailscale: String? {
        settings.babyAddresses.first { Reach.split($0).map { Reach.isTailscale($0.host) } ?? false }
    }

    private func otherCheck() async -> Bool {
        if MonitorEngine.isDemo { return true }
        switch (settings.source, settings.cameraKind) {
        case (.phone, _): return babyTailscale != nil
        case (.camera, .go2rtc):
            let host = settings.trimmedRemoteHost
            guard !host.isEmpty else { return false }
            return await Reach.canConnect(host: host, port: Go2rtc.rtspPort, timeout: 2)
        case (.camera, .rtsp): return await directRouteCheck()
        }
    }

    /// The camera answers at its home address while this phone is away from home, with Tailscale on.
    /// At home it answers anyway, so it can be verified only away. Once seen, it is remembered.
    private func directRouteCheck() async -> Bool {
        let key = "directRemoteOK"
        guard let camera = cameraAddress else { return false }
        if UserDefaults.standard.string(forKey: key) == camera.host { return true }
        let ownPrefix = CameraFinder.homeNetwork()?.prefix
        let away = ownPrefix != camera.host.split(separator: ".").prefix(3).joined(separator: ".")
        guard hereOK, away else { return false }
        guard await Reach.canConnect(host: camera.host, port: camera.port, timeout: 2) else { return false }
        UserDefaults.standard.set(camera.host, forKey: key)
        Log.shared.add("camera reached away from home through Tailscale")
        return true
    }

    /// The host and the port of the camera read directly, also for "Jiná kamera" (a full address).
    private var cameraAddress: (host: String, port: UInt16)? {
        guard let u = URLComponents(string: settings.rtspURL(small: false)), let host = u.host, !host.isEmpty else { return nil }
        return (host, UInt16(exactly: u.port ?? 554) ?? 554)
    }

    private func applyRemote() {
        let r = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.source == .camera, settings.cameraKind == .go2rtc, r != settings.trimmedRemoteHost else { return }
        settings.remoteHost = r
        engine.reconnect(why: "new remote address")
        Task { await camera.loadConfig() }
    }

    private func checklistRow<Extra: View>(_ title: String, ok: Bool, help: String, @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title3).foregroundStyle(ok ? Theme.calm : Color.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body.weight(.semibold))
                if !ok { Text(help).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                extra()
            }
        }
        .padding(.vertical, 4)
    }
}
