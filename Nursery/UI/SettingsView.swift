import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var engine: MonitorEngine
    @EnvironmentObject private var camera: CameraControl
    @EnvironmentObject private var battery: BatteryMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""

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
                    Picker(selection: $settings.quality) {
                        ForEach(Settings.Quality.allCases) { Text($0.title).tag($0) }
                    } label: {
                        Label("Kvalita obrazu", systemImage: "sparkles.tv")
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
                    TextField("192.168.0.136", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(applyHost)
                    if host.trimmingCharacters(in: .whitespaces) != settings.trimmedHost {
                        Button("Připojit k této adrese", action: applyHost)
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("Počítač, na kterém běží go2rtc. Chůvička čte obraz z go2rtc, nikdy přímo z kamery, protože kamera zvládne jen dvě připojení.")
                }

                Section("Stav") {
                    row("Připojení", connectionText)
                    row("Zvuk", engine.soundStatus.title)
                    row("Zpoždění zvuku", "\(engine.delayMilliseconds) ms")
                    row("Obraz", "\(Int(engine.videoSize.width)) × \(Int(engine.videoSize.height))")
                    row("Ovládání kamery", camera.ptzReady ? "Připraveno" : "Nenalezeno")
                    row("Baterie", battery.summary)
                    Button("Znovu připojit") { engine.reconnect(why: "settings") }
                    Button("Znovu načíst ovládání kamery") { Task { await camera.loadConfig() } }
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
                    Text("Chůvička funguje jen v domácí síti. Obraz ani zvuk nikdy neopustí váš domov.")
                }
            }
            .navigationTitle("Nastavení")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Hotovo") { applyHost(); dismiss() } }
            }
            .onAppear { host = settings.host }
        }
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
