import SwiftUI

@main
struct NurseryApp: App {
    @StateObject private var settings: Settings
    @StateObject private var engine: MonitorEngine
    @StateObject private var camera: CameraControl
    @Environment(\.scenePhase) private var phase
    @State private var started = false

    init() {
        let s = Settings()
        _settings = StateObject(wrappedValue: s)
        _engine = StateObject(wrappedValue: MonitorEngine(settings: s))
        _camera = StateObject(wrappedValue: CameraControl(settings: s))
    }

    /// Light is the default. Night mode and the picture are always dark.
    private var scheme: ColorScheme? {
        switch settings.appearance {
        case .light: .light
        case .dark: .dark
        case .automatic: nil
        }
    }

    var body: some Scene {
        WindowGroup {
            MonitorView()
                .environmentObject(settings)
                .environmentObject(engine)
                .environmentObject(camera)
                .preferredColorScheme(scheme)
                .tint(Theme.accent)
                .environment(\.locale, Locale(identifier: "cs_CZ"))   // Czech dates and times, also on an English phone.
                .task {
                    guard !started else { return }
                    started = true
                    engine.start()
                    UIApplication.shared.isIdleTimerDisabled = settings.keepAwake
                    await camera.loadConfig()
                }
                .onChange(of: settings.keepAwake) { _, on in UIApplication.shared.isIdleTimerDisabled = on }
        }
        .onChange(of: phase) { _, p in
            guard started else { return }
            switch p {
            case .active: engine.sceneBecameActive()
            case .background: engine.sceneEnteredBackground()
            default: break
            }
        }
    }
}
