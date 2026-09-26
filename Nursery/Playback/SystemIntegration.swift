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
            MPMediaItemPropertyTitle: "Chůvička",
            MPMediaItemPropertyArtist: status.title,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
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
    private var pendingStatus: NurseryActivityAttributes.Status?
    private var pendingSince = Date()
    private var chain: Task<Void, Never>?

    /// iOS ends a Live Activity after 8 hours. Start a new one before that, when the app is open.
    private static let renewAfter: TimeInterval = 7 * 3600

    init() {
        // An activity from an earlier run belongs to a dead process. End it.
        for old in Activity<NurseryActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// It sends a status change only when the status holds for 2 s (a lost sound goes at once),
    /// so a flapping status does not spend the update budget. It never sets a stale date:
    /// in the background iOS may refuse the updates, and a stale date would then falsely say
    /// that the app stopped.
    func update(status: NurseryActivityAttributes.Status, enabled: Bool) {
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else { end(); return }
        let now = Date()
        let appActive = UIApplication.shared.applicationState == .active

        if let a = activity, a.activityState == .dismissed || a.activityState == .ended {
            activity = nil                              // The user swiped it away, or iOS ended it.
            current = nil
        }
        if let a = activity, appActive, now.timeIntervalSince(a.attributes.started) > Self.renewAfter {
            end()                                       // Renew before the 8-hour limit.
        }

        guard let activity else {
            guard appActive else { return }            // Only the foreground can start an activity.
            let state = NurseryActivityAttributes.ContentState(status: status, since: now)
            do {
                self.activity = try Activity<NurseryActivityAttributes>.request(
                    attributes: NurseryActivityAttributes(room: "Chůvička", started: now),
                    content: ActivityContent(state: state, staleDate: nil), pushType: nil)
                current = state
            } catch {
                Log.shared.add("live activity not started: \(error.localizedDescription)")
            }
            return
        }

        guard status != current?.status else { pendingStatus = nil; return }
        if pendingStatus != status {
            pendingStatus = status
            pendingSince = now
        }
        guard status == .lost || now.timeIntervalSince(pendingSince) >= 2 else { return }
        pendingStatus = nil
        let state = NurseryActivityAttributes.ContentState(status: status, since: now)
        current = state
        let content = ActivityContent(state: state, staleDate: nil)
        let previous = chain
        chain = Task {                                  // In order, never two at once.
            await previous?.value
            await activity.update(content)
        }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        current = nil
        pendingStatus = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}

// MARK: - The notifications

@MainActor
enum NurseryAlerts {
    private static let lossID = "nursery.sound.lost"
    private static let soundID = "nursery.sound.event"
    private static let watchdogID = "nursery.watchdog"
    private static let interruptedID = "nursery.interrupted"

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func postLoss() {
        post(id: lossID, title: "Spojení s pokojíčkem se přerušilo",
             body: "Zvuk vypadl. Chůvička se pokusí připojit znovu sama.")
    }

    /// The watchdog. While the app runs in the background, it moves this notification
    /// 150 s into the future each 30 s. If iOS stops the app, or the app crashes, nothing moves it,
    /// and it fires. This is the one signal that works when the app itself cannot run.
    static func armWatchdog() {
        let content = UNMutableNotificationContent()
        content.title = "Chůvička přestala hlídat"
        content.body = "Aplikace neběží, takže dětský pokoj neslyšíte. Otevřete ji znovu."
        content.sound = .default
        content.interruptionLevel = .active
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 150, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: watchdogID, content: content, trigger: trigger))
    }

    static func disarmWatchdog() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [watchdogID])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [watchdogID])
    }

    static func clearLoss() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [lossID])
    }

    /// Another sound took the audio, and iOS is about to suspend the app before it got it back.
    static func postInterrupted() {
        post(id: interruptedID, title: "Hlídání přerušil jiný zvuk",
             body: "Chůvička teď neposlouchá. Klepnutím hlídání obnovíte.")
    }

    static func clearInterrupted() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [interruptedID])
    }

    static func postSound(at date: Date) {
        let time = date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "cs_CZ")))
        post(id: soundID, title: "Miminko se ozvalo", body: "V \(time). Klepnutím zobrazíte kameru.")
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
        c.canStartPictureInPictureAutomaticallyFromInline = automatic   // Swipe home: the small window opens.
        c.requiresLinearPlayback = true
        observation = c.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            DispatchQueue.main.async { self?.isPossible = c.isPictureInPicturePossible }
        }
        controller = c
    }

    /// A swipe home opens the small window. The sound view turns this off.
    var automatic = true {
        didSet { controller?.canStartPictureInPictureAutomaticallyFromInline = automatic }
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
