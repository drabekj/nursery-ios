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
                    TextField("192.168.0.136", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(applyHost)
                    if host.trimmingCharacters(in: .whitespaces) != settings.trimmedHost {
                        Button("Connect to this address", action: applyHost)
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("The address of the computer that runs go2rtc. The app reads the stream from go2rtc, and never from the camera. The camera accepts only 2 connections.")
                }

                Section("Picture") {
                    Picker("Quality", selection: $settings.quality) {
                        ForEach(Settings.Quality.allCases) { Text($0.title).tag($0) }
                    }
                }

                Section {
                    Picker("Loudness", selection: $settings.loudness) {
                        ForEach(Settings.Loudness.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Alert when the sound stops", isOn: $settings.alertOnLoss)
                        .onChange(of: settings.alertOnLoss) { _, on in if on { LossAlert.requestPermission() } }
                    Toggle("Show on the lock screen", isOn: $settings.liveActivity)
                } header: {
                    Text("Sound")
                } footer: {
                    Text("Loud adds 12 dB and Max adds 20 dB, for a quiet room. The side buttons of the phone set the volume. The alert comes when the app hears nothing for 20 seconds.")
                }

                Section {
                    Toggle("Keep the screen on", isOn: $settings.keepAwake)
                } header: {
                    Text("Screen")
                } footer: {
                    Text("Only while the app is open. Night mode (the moon) makes the screen almost black.")
                }

                Section("Status") {
                    row("Connection", connectionText)
                    row("Sound", engine.soundStatus.title)
                    row("Sound delay", "\(engine.delayMilliseconds) ms")
                    row("Picture", "\(Int(engine.videoSize.width))×\(Int(engine.videoSize.height))")
                    row("Camera control", camera.ptzReady ? "Ready" : "Not found")
                    NavigationLink("Event log") { EventLogView() }
                }

                Section {
                    Button("Reconnect now") { engine.reconnect(why: "settings") }
                    Button("Reload the camera control") { Task { await camera.loadConfig() } }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { applyHost(); dismiss() } }
            }
            .onAppear { host = settings.host }
        }
        .presentationDragIndicator(.visible)
    }

    private var connectionText: String {
        switch engine.connection {
        case .idle: "Closed"
        case .connecting: "Connecting"
        case .live: engine.audioOnly ? "Live (sound only)" : "Live"
        case .retrying: "Retrying"
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
        .navigationTitle("Event log")
        .toolbar { ShareLink(item: log.text) }
    }
}
