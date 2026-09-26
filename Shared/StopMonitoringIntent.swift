import ActivityKit
import AppIntents
import Foundation

extension Notification.Name {
    /// The Live Activity's "Ukončit hlídání" button: the app stops the monitor.
    static let stopMonitoring = Notification.Name("cz.drabek.nursery.stopMonitoring")
}

/// "Ukončit hlídání" on the lock screen. A LiveActivityIntent runs in the app's process, so the monitor
/// stops for real: no stream, no sound, no alerts. It also ends the activity at once.
struct StopMonitoringIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Ukončit hlídání"
    static let description = IntentDescription("Chůvička přestane poslouchat a zmizí ze zamčené obrazovky.")

    func perform() async throws -> some IntentResult {
        await MainActor.run { NotificationCenter.default.post(name: .stopMonitoring, object: nil) }
        for activity in Activity<NurseryActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        return .result()
    }
}
