import SwiftUI

@main
struct NurseryApp: App {
    @StateObject private var settings: Settings
    @StateObject private var engine: MonitorEngine
    @StateObject private var camera: CameraControl
    @StateObject private var battery = BatteryMonitor()
    @StateObject private var babyUnit: BabyUnit
    @Environment(\.scenePhase) private var phase
    @State private var started = false

    init() {
        let s = Settings()
        _settings = StateObject(wrappedValue: s)
        _engine = StateObject(wrappedValue: MonitorEngine(settings: s))
        _camera = StateObject(wrappedValue: CameraControl(settings: s))
        _babyUnit = StateObject(wrappedValue: BabyUnit(settings: s))
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
            Group {
                // The same app on both phones: the parent watches, the iPhone at the baby sends.
                if settings.role == .baby { BabyUnitView() } else { MonitorView() }
            }
                .environmentObject(settings)
                .environmentObject(babyUnit)
                .environmentObject(engine)
                .environmentObject(camera)
                .environmentObject(battery)
                .preferredColorScheme(scheme)
                .tint(Theme.accent)
                .environment(\.locale, Locale(identifier: "cs_CZ"))   // Czech dates and times, also on an English phone.
                .task {
                    guard !started else { return }
                    started = true
                    battery.start()
                    engine.snapshotProvider = { [camera] in await camera.snapshot() }
                    if settings.role == .baby {
                        engine.suspend()
                        return
                    }
                    engine.start()
                    UIApplication.shared.isIdleTimerDisabled = settings.keepAwake
                    if settings.source == .camera { await camera.loadConfig() }
                }
                .onChange(of: settings.keepAwake) { _, on in
                    if settings.role == .parent { UIApplication.shared.isIdleTimerDisabled = on }
                }
                .onChange(of: settings.role) { _, role in
                    switch role {
                    case .baby:
                        engine.suspend()
                    case .parent:
                        babyUnit.stop()
                        engine.resume()
                        UIApplication.shared.isIdleTimerDisabled = settings.keepAwake
                    }
                }
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
