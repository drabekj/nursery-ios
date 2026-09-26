import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var engine: MonitorEngine
    @EnvironmentObject private var camera: CameraControl
    @EnvironmentObject private var battery: BatteryMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var confirmBaby = false
    @State private var confirmClear = false
    @State private var advanced = false
    @State private var path: [Page] = []

    enum Page: Hashable { case remote, help, log }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    Button(action: changeCamera) {
                        HStack {
                            LabeledContent {
                                Text(cameraText).foregroundStyle(.secondary)
                            } label: {
                                Label {
                                    Text("Kamera").foregroundStyle(.primary)
                                } icon: {
                                    Image(systemName: "web.camera")
                                }
                            }
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Section {
                    Picker(selection: $settings.sensitivity) {
                        ForEach(Settings.Sensitivity.allCases) { Text($0.title).tag($0) }
                    } label: {
                        Label("Citlivost", systemImage: "waveform.badge.magnifyingglass")
                    }
                } footer: {
                    Text("Citlivost určuje, co se počítá jako zvuk – pro upozornění i pro Přehled.")
                }

                Section {
                    Picker(selection: $settings.loudness) {
                        ForEach(Settings.Loudness.allCases) { Text($0.title).tag($0) }
                    } label: {
                        Label("Hlasitost", systemImage: "speaker.plus")
                    }
                } footer: {
                    Text("Zesílená se hodí do tichého pokoje. Celkovou hlasitost dál ovládáte tlačítky na boku telefonu.")
                }

                Section {
                    Toggle(isOn: $settings.alertOnSound) {
                        Label("Upozornit na pláč i když zvuk hraje", systemImage: "bell.badge")
                    }
                } header: {
                    Text("Upozornění")
                } footer: {
                    Text("Na výpadek spojení a na pláč při ztlumeném nebo tichém zvuku Chůvička upozorní vždy. Upozornění chodí nejvýš jednou za minutu.")
                }
                .onChange(of: settings.alertOnSound) { _, on in if on { NurseryAlerts.requestPermission() } }

                Section {
                    Button {
                        confirmBaby = true
                    } label: {
                        Label("Použít tento telefon u miminka", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    }
                } footer: {
                    Text("Tento telefon pak nehlídá, ale vysílá: jeho kamera a mikrofon budou u postýlky. Hodí se starší telefon.")
                }
                .confirmationDialog("Používat tento telefon u miminka?", isPresented: $confirmBaby, titleVisibility: .visible) {
                    Button("Ano, bude vysílat") {
                        settings.role = .baby
                        dismiss()
                    }
                } message: {
                    Text("Hlídání na tomto telefonu se vypne. Zpět ho přepnete na obrazovce telefonu u miminka.")
                }

                Section {
                    NavigationLink(value: Page.help) {
                        Label("Nápověda", systemImage: "questionmark.circle")
                    }
                }

                Section {
                    DisclosureGroup(isExpanded: $advanced) {
                        advancedRows
                    } label: {
                        Label("Pro pokročilé", systemImage: "gearshape.2")
                    }
                }

                Section {
                    row("Verze", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                } footer: {
                    Text("Doma jde obraz v domácí síti, mimo domov šifrovaně přes vaši soukromou síť. Obraz ani zvuk nikdy nejdou přes cizí server.")
                }
            }
            .navigationTitle("Nastavení")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .remote: RemoteAccessView()
                case .help: HelpList()
                case .log: EventLogView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Hotovo") { applyHost(); dismiss() } }
            }
            .confirmationDialog("Smazat historii a fotky?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Smazat historii", role: .destructive) { engine.activityLog.clear() }
            }
        }
        // On the stack, not on the Form: the Form appears again after each Zpět.
        .onAppear {
            host = settings.host
            if MonitorEngine.isDemo {
                switch UserDefaults.standard.string(forKey: "demoScreen") {
                case "remote": path = [.remote]
                case "settings-advanced": advanced = true
                default: break
                }
            }
        }
    }

    /// Behind "Pro pokročilé": what a parent does not need for the first night.
    @ViewBuilder private var advancedRows: some View {
        Toggle(isOn: $settings.keepAwake) {
            Label("Nevypínat displej", systemImage: "sun.max")
        }
        Picker(selection: $settings.appearance) {
            ForEach(Settings.Appearance.allCases) { Text($0.title).tag($0) }
        } label: {
            Label("Vzhled", systemImage: "circle.lefthalf.filled")
        }
        addressRows
        statusRows
        Button("Smazat historii", role: .destructive) { confirmClear = true }
        NavigationLink(value: Page.log) {
            Text("Technický záznam")
        }
        Button("Spustit průvodce znovu") {
            UserDefaults.standard.removeObject(forKey: "wizardStart")
            dismiss()
            settings.onboarded = false
        }
    }

    /// Where the picture comes from: the server address, away from home, the camera controls.
    @ViewBuilder private var addressRows: some View {
        if server {
            LabeledContent("Adresa doma") {
                TextField(HomeDefaults.serverHost.isEmpty ? "192.168.0.10" : HomeDefaults.serverHost, text: $host)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(applyHost)
            }
            if host.trimmingCharacters(in: .whitespaces) != settings.trimmedHost {
                Button("Použít tuto adresu", action: applyHost)
            }
        }
        NavigationLink(value: Page.remote) {
            Label("Mimo domov", systemImage: "globe")
        }
        if server {
            Toggle(isOn: $settings.cameraControl) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Natočit kameru (Home Assistant)")
                    Text("Šipky pro natočení kamery přes Home Assistant. Jen pro server s tímto nastavením.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: settings.cameraControl) { _, _ in Task { await camera.loadConfig() } }
        }
    }

    /// The state of the connection, for when something does not work.
    @ViewBuilder private var statusRows: some View {
        row("Připojení", connectionText)
        row("Cesta", engine.viaTailscale ? "Mimo domov" : "Doma")
        row("Zvuk", engine.soundStatus.title)
        row("Zpoždění", "\(engine.delayMilliseconds) ms")
        row("Obraz", "\(Int(engine.videoSize.width)) × \(Int(engine.videoSize.height))" + (engine.detailActive ? " · detail" : ""))
        if aims {
            row("Ovládání kamery", camera.ptzReady ? "Připraveno" : "Nenalezeno")
        }
        row("Baterie", battery.summary)
        Button("Znovu připojit") { engine.reconnect(why: "settings") }
        if aims {
            Button("Znovu načíst ovládání kamery") { Task { await camera.loadConfig() } }
        }
    }

    /// The go2rtc server: its address and the camera controls live only there.
    private var server: Bool { settings.source == .camera && settings.cameraKind == .go2rtc }
    private var aims: Bool { server && settings.cameraControl }

    /// What is connected, in the words of the guide.
    private var cameraText: String {
        switch (settings.source, settings.cameraKind) {
        case (.phone, _):
            settings.babyName.isEmpty ? "Nespárováno" : "Telefon u miminka „\(settings.babyName)“"
        case (.camera, .rtsp):
            settings.rtspBrand == .other ? settings.rtspBrand.title
                : "\(settings.rtspBrand.title) · \(settings.rtspHost.trimmingCharacters(in: .whitespaces))"
        case (.camera, .go2rtc):
            "Server · \(settings.trimmedHost)"
        }
    }

    /// The guide again, but at the source step: the Welcome and the role are known.
    private func changeCamera() {
        UserDefaults.standard.set("source", forKey: "wizardStart")
        dismiss()
        settings.onboarded = false
    }

    private var connectionText: String {
        switch engine.overall {
        case .live: "Živě"
        case .soundOnly: "Živě (jen zvuk)"
        case .connecting: "Připojování"
        case .reconnecting: "Obnovování spojení"
        case .offline: "Nedostupné"
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).monospacedDigit() }
    }

    private func applyHost() {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, h != settings.trimmedHost else { return }
        settings.host = h
        engine.reconnect(why: "new server address")
        Task { await camera.loadConfig() }
    }
}

struct EventLogView: View {
    @ObservedObject private var log = Log.shared

    var body: some View {
        List(log.entries.reversed()) { e in
            VStack(alignment: .leading, spacing: 2) {
                Text(e.time, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(e.text).font(.callout)
            }
        }
        .overlay { if log.entries.isEmpty { ContentUnavailableView("Žádné události", systemImage: "list.bullet.rectangle") } }
        .navigationTitle("Technický záznam")
        .toolbar { ShareLink(item: log.text) }
    }
}
