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
        /// The room word when the app last ran in the foreground. The widget colours its circle by
        /// it, and shows no word: in the background it cannot stay true.
        var state: RoomState = .calm

        enum CodingKeys: String, CodingKey { case status, since, state }
    }

    var room: String
    /// When the monitoring started. The widget shows "od 21:40" from it, with no updates.
    var started: Date
}

extension NurseryActivityAttributes.ContentState {
    /// A state from 1.9 has no room word.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(NurseryActivityAttributes.Status.self, forKey: .status)
        since = try c.decode(Date.self, forKey: .since)
        state = try c.decodeIfPresent(RoomState.self, forKey: .state) ?? .calm
    }
}

/// What the room is doing, in one word. The big word on the screen, the colour of the field,
/// the title of a notification. It is derived twice a second from three things the engine
/// already has: the sound status, the sound event of `SoundActivity`, and the cry classifier.
///
/// The words are honest: "Klid" means the room is quiet, not that the baby sleeps. "Pláče" means
/// the classifier heard a baby cry during a loud stretch; without a classifier it means "loud for
/// a while", and Nápověda says so.
enum RoomState: String, Codable, Sendable {
    /// The start: the app has not heard the room yet.
    case connecting
    /// Quiet, or nothing above the noise floor.
    case calm
    /// A sound event runs: something is louder than the room. A sigh, a dog, a door, a cry that
    /// the classifier has not confirmed yet.
    case sound
    /// A baby cry, confirmed by the classifier (or by loudness and duration without one).
    case cry
    /// No sound for 20 s: the app does not hear the room.
    case lost

    var title: String {
        switch self {
        case .connecting: "Připojuji…"
        case .calm: "Klid"
        case .sound: "Ozývá se"
        case .cry: "Pláče"
        case .lost: "Nehlídá"
        }
    }
}
