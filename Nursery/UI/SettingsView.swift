import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var engine: MonitorEngine
    @EnvironmentObject private var camera: CameraControl
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $engine.mode) {
                        ForEach(MonitorEngine.SoundMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    } label: {
                        Label("Sound", systemImage: "speaker.wave.2")
                    }
                    Picker(selection: $settings.loudness) {
                        ForEach(Settings.Loudness.allCases) { Text($0.title).tag($0) }
                    } label: {
                        Label("Loudness", systemImage: "speaker.plus")
                    }
                } header: {
                    Text("Sound")
                } footer: {
                    Text("Silent plays nothing, but Nursery keeps listening and alerts you when the baby makes a sound. Loud adds 12 dB and Max adds 20 dB for a quiet room; the side buttons still set the volume.")
                }

                Section {
                    Picker(selection: $settings.sensitivity) {
                        ForEach(Settings.Sensitivity.allCases) { Text($0.title).tag($0) }
                    } label: {
                        Label("Sensitivity", systemImage: "waveform.badge.magnifyingglass")
                    }
                    Toggle(isOn: $settings.alertOnSound) {
                        Label("Alert on sound in Live mode", systemImage: "bell.badge")
                    }
                    Toggle(isOn: $settings.alertOnLoss) {
                        Label("Alert when the sound stops", systemImage: "wifi.exclamationmark")
                    }
                    Toggle(isOn: $settings.liveActivity) {
                        Label("Show on the Lock Screen", systemImage: "platter.filled.bottom.iphone")
                    }
                } header: {
                    Text("Alerts")
                } footer: {
                    Text("Sensitivity sets what counts as a sound, for the alerts and the Activity. Alerts come only while Nursery is in the background, at most one each minute.")
                }
                .onChange(of: settings.alertOnSound) { _, on in if on { NurseryAlerts.requestPermission() } }
                .onChange(of: settings.alertOnLoss) { _, on in if on { NurseryAlerts.requestPermission() } }

                Section {
                    Picker(selection: $settings.quality) {
                        ForEach(Settings.Quality.allCases) { Text($0.title).tag($0) }
                    } label: {
                        Label("Quality", systemImage: "sparkles.tv")
                    }
                    Toggle(isOn: $settings.keepAwake) {
                        Label("Keep the Screen On", systemImage: "sun.max")
                    }
                    Picker(selection: $settings.appearance) {
                        ForEach(Settings.Appearance.allCases) { Text($0.title).tag($0) }
                    } label: {
                        Label("Appearance", systemImage: "circle.lefthalf.filled")
                    }
                } header: {
                    Text("Screen")
                } footer: {
                    Text("Keep the Screen On works only while Nursery is open. Night mode is always dark, and makes the screen almost black.")
                }

                Section {
                    TextField("192.168.0.136", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(applyHost)
                    if host.trimmingCharacters(in: .whitespaces) != settings.trimmedHost {
                        Button("Connect to This Address", action: applyHost)
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("The computer that runs go2rtc. Nursery reads the stream from go2rtc and never from the camera, which accepts only two connections.")
                }

                Section("Status") {
                    row("Connection", connectionText)
                    row("Sound", engine.soundStatus.title)
                    row("Sound delay", "\(engine.delayMilliseconds) ms")
                    row("Picture", "\(Int(engine.videoSize.width)) × \(Int(engine.videoSize.height))")
                    row("Camera control", camera.ptzReady ? "Ready" : "Not found")
                    NavigationLink("Event Log") { EventLogView() }
                    Button("Reconnect Now") { engine.reconnect(why: "settings") }
                    Button("Reload Camera Control") { Task { await camera.loadConfig() } }
                }

                Section {
                    row("Version", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                } footer: {
                    Text("Nursery works only on your home network. No picture or sound leaves the house.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { applyHost(); dismiss() } }
            }
            .onAppear { host = settings.host }
        }
    }

    private var connectionText: String {
        switch engine.overall {
        case .live: "Live"
        case .soundOnly: "Live (sound only)"
        case .connecting: "Connecting"
        case .reconnecting: "Reconnecting"
        case .offline: "Offline"
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
        .overlay { if log.entries.isEmpty { ContentUnavailableView("No Events", systemImage: "list.bullet.rectangle") } }
        .navigationTitle("Event Log")
        .toolbar { ShareLink(item: log.text) }
    }
}
