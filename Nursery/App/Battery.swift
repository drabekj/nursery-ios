import Combine
import UIKit

/// It measures the real battery drain on this phone, while it is not charging.
/// A general number ("about 5 % per hour") depends on the phone, the brightness, and the Wi-Fi.
/// A measured number is true for this phone and this night.
@MainActor
final class BatteryMonitor: ObservableObject {
    @Published private(set) var level: Float = -1          // 0...1, or -1 if not known.
    @Published private(set) var charging = false
    /// Percent per hour, measured over the last 15 to 90 minutes without a charger.
    @Published private(set) var drainPerHour: Double?

    private var samples: [(time: Date, level: Float)] = []
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        if MonitorEngine.isDemo {
            level = 0.64
            drainPerHour = 4.5
            return
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    /// How many hours the battery lasts at the measured rate.
    var hoursLeft: Double? {
        guard !charging, level >= 0, let drain = drainPerHour, drain > 0.3 else { return nil }
        return Double(level) * 100 / drain
    }

    var isLow: Bool { level >= 0 && level < 0.25 && !charging }

    /// "64 %", "64 % · nabíjí se", "64 % · asi 5 % za hodinu · vydrží asi 12 h".
    var summary: String {
        guard level >= 0 else { return "Stav baterie není známý" }
        let percent = "\(Int((level * 100).rounded())) %"
        if charging { return "\(percent) · nabíjí se" }
        guard let drain = drainPerHour else { return "\(percent) · spotřebu měřím…" }
        var text = "\(percent) · asi \(Int(drain.rounded())) % za hodinu"
        if let h = hoursLeft { text += " · vydrží asi \(Int(h.rounded(.down))) h" }
        return text
    }

    private func sample() {
        let device = UIDevice.current
        level = device.batteryLevel
        charging = device.batteryState == .charging || device.batteryState == .full
        guard !charging, level >= 0 else {
            samples.removeAll()          // A charger breaks the measurement. Start again.
            drainPerHour = nil
            return
        }
        let now = Date()
        samples.append((now, level))
        samples.removeAll { now.timeIntervalSince($0.time) > 90 * 60 }
        guard let first = samples.first else { return }
        let hours = now.timeIntervalSince(first.time) / 3600
        guard hours >= 0.25 else { return }                     // 15 minutes at least.
        drainPerHour = max(0, Double(first.level - level) * 100 / hours)
    }
}
