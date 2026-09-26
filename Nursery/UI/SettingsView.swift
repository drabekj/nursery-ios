import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var engine: MonitorEngine
    @EnvironmentObject private var camera: CameraControl
    @EnvironmentObject private var battery: BatteryMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var remote = ""
    @State private var confirmBaby = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $engine.mode) {
                        ForEach(MonitorEngine.SoundMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    } label: {
                        Label("Režim zvuku", systemImage: "speaker.wave.2")
                    }
                    Picker(selection: $settings.loudness) {
                        ForEach(Settings.Loudness.allCases) { Text($0.title).tag($0) }
                    } label: {
                        Label("Hlasitost", systemImage: "speaker.plus")
                    }
                } header: {
                    Text("Zvuk")
                } footer: {
                    Text("V tichém režimu Chůvička nic nepřehrává, ale dál poslouchá a upozorní vás, když se miminko ozve. Zesílená hlasitost přidá 12 dB, maximální 20 dB – hodí se do tichého pokoje. Celkovou hlasitost dál ovládáte tlačítky na boku telefonu.")
                }

                Section {
                    Picker(selection: $settings.sensitivity) {
                        ForEach(Settings.Sensitivity.allCases) { Text($0.title).tag($0) }
                    } label: {
                        Label("Citlivost", systemImage: "waveform.badge.magnifyingglass")
                    }
                    Toggle(isOn: $settings.alertOnSound) {
                        Label("Upozornit na zvuk i při živém zvuku", systemImage: "bell.badge")
                    }
                    Toggle(isOn: $settings.alertOnLoss) {
                        Label("Upozornit na výpadek zvuku", systemImage: "wifi.exclamationmark")
                    }
                    Toggle(isOn: $settings.liveActivity) {
                        Label("Zobrazit na zamčené obrazovce", systemImage: "platter.filled.bottom.iphone")
                    }
                } header: {
                    Text("Upozornění")
                } footer: {
                    Text("Citlivost určuje, co se počítá jako zvuk – pro upozornění i pro Přehled. Upozornění chodí, jen když Chůvička běží na pozadí, a nejvýš jednou za minutu.")
                }
                .onChange(of: settings.alertOnSound) { _, on in if on { NurseryAlerts.requestPermission() } }
                .onChange(of: settings.alertOnLoss) { _, on in if on { NurseryAlerts.requestPermission() } }

                Section {
                    if settings.source == .camera {
                        Picker(selection: $settings.quality) {
                            ForEach(Settings.Quality.allCases) { Text($0.title).tag($0) }
                        } label: {
                            Label("Kvalita obrazu", systemImage: "sparkles.tv")
                        }
                    }
                    Toggle(isOn: $settings.keepAwake) {
                        Label("Nevypínat displej", systemImage: "sun.max")
                    }
                    Picker(selection: $settings.appearance) {
                        ForEach(Settings.Appearance.allCases) { Text($0.title).tag($0) }
                    } label: {
                        Label("Vzhled", systemImage: "circle.lefthalf.filled")
                    }
                } header: {
                    Text("Displej")
                } footer: {
                    Text("Displej zůstane zapnutý, jen když je Chůvička otevřená. Noční režim je vždy tmavý a displej téměř zhasne.")
                }

                Section {
                    Picker(selection: $settings.source) {
                        ForEach(Settings.Source.allCases) { Text($0.title).tag($0) }
                    } label: {
                        Label("Obraz a zvuk z", systemImage: "dot.radiowaves.left.and.right")
                    }
                    if settings.source == .camera {
                        TextField(HomeDefaults.serverHost.isEmpty ? "IP adresa serveru" : HomeDefaults.serverHost, text: $host)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(applyHost)
                        LabeledContent("Mimo domov") {
                            TextField("Adresa přes Tailscale", text: $remote)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numbersAndPunctuation)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .onSubmit(applyHost)
                        }
                        if host.trimmingCharacters(in: .whitespaces) != settings.trimmedHost
                            || remote.trimmingCharacters(in: .whitespaces) != settings.trimmedRemoteHost {
                            Button("Použít tyto adresy", action: applyHost)
                        }
                    } else {
                        NavigationLink {
                            PairingView()
                        } label: {
                            LabeledContent {
                                Text(settings.babyName.isEmpty ? "Nespárováno" : settings.babyName)
                            } label: {
                                Label("Telefon u miminka", systemImage: "iphone.gen3")
                            }
                        }
                    }
                } header: {
                    Text("Zdroj")
                } footer: {
                    if settings.source == .camera {
                        Text("Počítač, na kterém běží go2rtc. Doma se Chůvička připojí na jeho adresu v síti. Mimo domov použije jeho adresu přes Tailscale, když je v telefonu Tailscale zapnutý.")
                    } else {
                        Text(babyFooter)
                    }
                }
                .onChange(of: settings.source) { _, source in
                    if source == .camera { Task { await camera.loadConfig() } }
                }

                Section {
                    Button {
                        confirmBaby = true
                    } label: {
                        Label("Použít jako telefon u miminka", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    }
                } header: {
                    Text("Tento iPhone")
                } footer: {
                    Text("Tento iPhone pak nehlídá, ale vysílá: jeho kamera a mikrofon budou u postýlky. Hodí se starší iPhone.")
                }
                .confirmationDialog("Používat tento telefon u miminka?", isPresented: $confirmBaby, titleVisibility: .visible) {
                    Button("Ano, bude vysílat") {
                        settings.role = .baby
                        dismiss()
                    }
                } message: {
                    Text("Hlídání na tomto telefonu se vypne. Zpět ho přepnete na obrazovce telefonu u miminka.")
                }

                Section("Stav") {
                    row("Připojení", connectionText)
                    row("Cesta", engine.viaTailscale ? "Přes Tailscale" : "Doma")
                    row("Zvuk", engine.soundStatus.title)
                    row("Zpoždění zvuku", "\(engine.delayMilliseconds) ms")
                    row("Obraz", "\(Int(engine.videoSize.width)) × \(Int(engine.videoSize.height))")
                    if settings.source == .camera {
                        row("Ovládání kamery", camera.ptzReady ? "Připraveno" : "Nenalezeno")
                    }
                    row("Baterie", battery.summary)
                    Button("Znovu připojit") { engine.reconnect(why: "settings") }
                    if settings.source == .camera {
                        Button("Znovu načíst ovládání kamery") { Task { await camera.loadConfig() } }
                    }
                }

                Section {
                    Button("Spustit průvodce nastavením") {
                        dismiss()
                        settings.onboarded = false
                    }
                }

                Section {
                    NavigationLink("Technický záznam") { EventLogView() }
                } header: {
                    Text("Diagnostika")
                } footer: {
                    Text("Podrobný záznam pro řešení potíží, třeba když zvuk v noci vypadl. Běžně ho nepotřebujete. Když něco nefunguje, pošlete ho tlačítkem Sdílet.")
                }

                Section {
                    row("Verze", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                } footer: {
                    Text("Doma jde obraz v domácí síti, mimo domov šifrovaně přes váš Tailscale. Obraz ani zvuk nikdy nejdou přes cizí server.")
                }
            }
            .navigationTitle("Nastavení")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Hotovo") { applyHost(); dismiss() } }
            }
            .onAppear { host = settings.host; remote = settings.remoteHost }
        }
    }

    private var babyFooter: String {
        let base = "Druhý telefon s Chůvičkou u postýlky, iPhone nebo Android, posílá obraz a zvuk přímo do tohoto telefonu. Nic neodchází na internet."
        let tailscale = settings.babyAddresses.first { Reach.split($0).map { Reach.isTailscale($0.host) } ?? false }
        if let tailscale { return base + " Mimo domov přes Tailscale: \(tailscale)." }
        return base + " Pro hlídání mimo domov nainstalujte Tailscale i na telefon u miminka a jednou se k němu připojte doma."
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
        let r = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, h != settings.trimmedHost || r != settings.trimmedRemoteHost else { return }
        settings.host = h
        settings.remoteHost = r
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
