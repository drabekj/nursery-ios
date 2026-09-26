import Foundation

/// The developer's home setup: his go2rtc server, its Tailscale address, and his stream names.
/// They are pre-filled, so his phones need no setup.
/// A public build sets them to empty strings. Nothing else must be deleted.
/// The addresses and the stream names are used only as the initial values of `Settings` and as
/// a placeholder in the settings. A value that the user saved always wins.
/// `configPath` is read at each config load. When it is empty, the app loads no config and
/// offers no camera control.
enum HomeDefaults {
    /// The go2rtc server on the home Wi-Fi (a Raspberry Pi).
    static let serverHost = "192.168.0.136"
    /// The same server on the tailnet ("rpi-host"), for use away from home.
    static let remoteHost = "100.104.188.72"
    /// The go2rtc stream names: the camera's main (high) stream and its sub (low) stream.
    static let streamMain = "nursery"
    static let streamSmall = "nursery_sd"
    /// The file that go2rtc serves, with the Home Assistant webhook ids. See `CameraControl`.
    static let configPath = "nursery/config.js"
}
