import ActivityKit
import Foundation

/// The Live Activity on the lock screen and in the Dynamic Island.
/// It shows whether the app hears the room, and how loud the room is.
struct NurseryActivityAttributes: ActivityAttributes {
    enum Status: String, Codable, Hashable {
        case listening, silent, connecting, lost

        var title: String {
            switch self {
            case .listening: "Živý zvuk"
            case .silent: "Ztlumeno"
            case .connecting: "Připojování…"
            case .lost: "Zvuk vypadl"
            }
        }
    }

    /// iOS refuses Live Activity updates from an app that runs in the background only for audio
    /// ("Process is only playing background media so is forbidden to update activity").
    /// So the activity shows only what stays true without updates: that the monitor runs,
    /// and since when. The live state in the background is in the Now Playing controls,
    /// and a real stop gives a notification (the watchdog in NurseryAlerts).
    struct ContentState: Codable, Hashable {
        var status: Status
        /// The start of the current status.
        var since: Date
    }

    var room: String
    /// When the monitoring started. The widget shows "od 21:40" from it, with no updates.
    var started: Date
}
