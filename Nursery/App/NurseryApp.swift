import SwiftUI

/// iOS tells the app delegate when the user closes the app.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var onTerminate: (() -> Void)?
    func applicationWillTerminate(_ application: UIApplication) { Self.onTerminate?() }
}

@main
struct NurseryApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
                if !settings.onboarded {
                    OnboardingView {
                        engine.resume()
                        if settings.source == .camera { Task { await camera.loadConfig() } }
                    }
                } else if settings.role == .baby { BabyUnitView() } else { MonitorView() }
            }
                // The pairing QR code also opens from the system camera.
                .onOpenURL { url in
                    guard let link = PairLink(url: url) else { return }
                    link.apply(to: settings)
                    if settings.onboarded, settings.role == .parent { engine.reconnect(why: "paired by link") }
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
                    AppDelegate.onTerminate = { [engine] in MainActor.assumeIsolated { engine.appWillTerminate() } }
                    // The phone at the baby, or the guide still open: the monitor waits.
                    if settings.role == .baby || !settings.onboarded {
                        engine.suspend()
                        return
                    }
                    engine.start()
                    UIApplication.shared.isIdleTimerDisabled = settings.keepAwake
                    if settings.source == .camera { await camera.loadConfig() }
                }
                // Away from home the Pi has another address: load the camera controls from there.
                .onChange(of: settings.activeHost) { _, _ in
                    if settings.source == .camera { Task { await camera.loadConfig() } }
                }
                .onChange(of: settings.keepAwake) { _, on in
                    if settings.role == .parent { UIApplication.shared.isIdleTimerDisabled = on }
                }
                // The guide again, from Settings: the monitor and the sending wait for it.
                .onChange(of: settings.onboarded) { _, done in
                    if !done { engine.suspend(); babyUnit.stop() }
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
