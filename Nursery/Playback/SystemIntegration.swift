import ActivityKit
import AVKit
import Combine
import MediaPlayer
import UIKit
import UserNotifications

// MARK: - The lock screen (Now Playing)

@MainActor
final class NowPlaying {
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    private var configured = false
    private lazy var artwork: MPMediaItemArtwork? = {
        guard let image = UIImage(named: "Artwork") else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }()

    func configure() {
        guard !configured else { return }
        configured = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.onPlay?(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.onPause?(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1 {
                self.onPause?()
            } else {
                self.onPlay?()
            }
            return .success
        }
        for cmd in [c.nextTrackCommand, c.previousTrackCommand, c.skipForwardCommand,
                    c.skipBackwardCommand, c.changePlaybackPositionCommand, c.seekForwardCommand, c.seekBackwardCommand] {
            cmd.isEnabled = false
        }
    }

    func update(status: NurseryActivityAttributes.Status) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "Nursery",
            MPMediaItemPropertyArtist: status.title,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: status == .muted ? 0.0 : 1.0,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

// MARK: - The Live Activity

@MainActor
final class LiveActivityController {
    private var activity: Activity<NurseryActivityAttributes>?
    private var current: NurseryActivityAttributes.ContentState?
    private var lastSent = Date.distantPast
    private var pending: Task<Void, Never>?

    init() {
        // An activity from an earlier run is stale. End it.
        for old in Activity<NurseryActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// The app must be in the foreground to start an activity. It can update it from the background.
    func update(status: NurseryActivityAttributes.Status, level: Int, enabled: Bool) {
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else { end(); return }
        let since = (current?.status == status ? current?.since : nil) ?? Date()
        let state = NurseryActivityAttributes.ContentState(status: status, level: level, since: since)
        guard state != current else { return }
        let statusChanged = state.status != current?.status
        current = state

        // If the app stops, the activity shows "stale" after 30 seconds. The parent then knows.
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(30))
        if let activity {
            // A level change goes out at most once each 1.5 s. A status change goes out at once.
            guard statusChanged || Date().timeIntervalSince(lastSent) > 1.5 else { return }
            lastSent = Date()
            Task { await activity.update(content) }
        } else if UIApplication.shared.applicationState == .active {
            do {
                activity = try Activity<NurseryActivityAttributes>.request(
                    attributes: NurseryActivityAttributes(room: "Nursery"), content: content, pushType: nil)
                lastSent = Date()
            } catch {
                Log.shared.add("live activity not started: \(error.localizedDescription)")
            }
        }
    }

    /// It keeps the stale date in the future while the app runs. It runs each 10 s.
    func heartbeat() {
        guard let activity, let current else { return }
        lastSent = Date()
        Task { await activity.update(ActivityContent(state: current, staleDate: Date().addingTimeInterval(30))) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        current = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}

// MARK: - The notifications

@MainActor
enum NurseryAlerts {
    private static let lossID = "nursery.sound.lost"
    private static let soundID = "nursery.sound.event"

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func postLoss() {
        post(id: lossID, title: "No sound from the nursery",
             body: "The connection to the camera stopped. Nursery tries again by itself.")
    }

    static func clearLoss() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [lossID])
    }

    static func postSound(at date: Date) {
        let time = date.formatted(date: .omitted, time: .shortened)
        post(id: soundID, title: "Sound in the nursery", body: "It started at \(time). Tap to look.")
    }

    private static func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .active
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

// MARK: - Picture in picture

/// It uses the sample buffer layer of the live view. A live stream has no time line,
/// so the playback delegate reports an infinite range and "never paused".
final class PictureInPicture: NSObject, ObservableObject, AVPictureInPictureControllerDelegate,
                              AVPictureInPictureSampleBufferPlaybackDelegate {
    @Published private(set) var isPossible = false
    @Published private(set) var isActive = false
    var onActiveChange: ((Bool) -> Void)?

    private var controller: AVPictureInPictureController?
    private var observation: NSKeyValueObservation?

    func attach(to layer: AVSampleBufferDisplayLayer) {
        guard controller == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: source)
        c.delegate = self
        c.canStartPictureInPictureAutomaticallyFromInline = true   // Swipe home: the small window opens.
        c.requiresLinearPlayback = true
        observation = c.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            DispatchQueue.main.async { self?.isPossible = c.isPictureInPicturePossible }
        }
        controller = c
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() }
        else { controller.startPictureInPicture() }
    }

    // AVPictureInPictureControllerDelegate
    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        set(active: true)
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        set(active: false)
    }
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        Log.shared.add("picture in picture failed: \(error.localizedDescription)")
        set(active: false)
    }
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }

    private func set(active: Bool) {
        DispatchQueue.main.async {
            self.isActive = active
            self.onActiveChange?(active)
        }
    }

    // AVPictureInPictureSampleBufferPlaybackDelegate
    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { false }
    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ c: AVPictureInPictureController) -> Bool { false }
}
