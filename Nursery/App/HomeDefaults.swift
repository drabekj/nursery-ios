import Foundation

/// The developer's home setup: his go2rtc server, its Tailscale address, and his stream names.
/// They are pre-filled, so his phones need no setup.
/// A public build sets them to empty strings. Nothing else must be deleted.
/// They are used only as the initial values of `Settings` and as placeholders in the settings.
/// A value that the user saved always wins: these are read only when no value is saved.
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
