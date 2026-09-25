import ActivityKit
import Foundation

/// The Live Activity on the lock screen and in the Dynamic Island.
/// It shows whether the app hears the room, and how loud the room is.
struct NurseryActivityAttributes: ActivityAttributes {
    enum Status: String, Codable, Hashable {
        case listening, silent, connecting, lost, muted

        var title: String {
            switch self {
            case .listening: "Živý zvuk"
            case .silent: "Tichý režim"
            case .connecting: "Připojování…"
            case .lost: "Zvuk vypadl"
            case .muted: "Zvuk vypnut"
            }
        }
    }

    struct ContentState: Codable, Hashable {
        var status: Status
        /// 0...4. The loudness of the room, in 5 steps.
        var level: Int
        /// The start of the current status.
        var since: Date
    }

    var room: String
}
