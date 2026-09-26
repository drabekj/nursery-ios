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
                Section {
                    Text("Kamera sama se mimo domov připojit neumí. Mimo domov miminko uvidíte, když místo kamery použijete telefon u miminka, nebo vlastní server.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Section {
                    checklistRow("Tailscale v tomto telefonu", ok: hereOK,
                                 help: "Nainstalujte Tailscale, přihlaste se a zapněte ho.") {
                        Link("Stáhnout Tailscale", destination: URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!)
                            .font(.subheadline.weight(.semibold))
                    }
                    other
                } footer: {
                    Text("Doma se Chůvička připojuje přímo. Tailscale použije sama, až budete pryč.")
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
        case (.camera, .rtsp): return false
        }
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
