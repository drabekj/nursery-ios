package cz.drabek.chuvicka

/**
 * The developer's home setup. It is pre-filled so that his phones need no setup.
 * A public build sets these to empty strings and deletes nothing else.
 * They are used only as the initial values of Settings and in the wizard placeholders.
 */
object HomeDefaults {
    /** The Pi with go2rtc, in the home network. */
    const val SERVER_HOST = "192.168.0.136"
    /** The Pi's Tailscale address, for the time away from home. */
    const val REMOTE_HOST = "100.104.188.72"
    /** The go2rtc stream names: the camera's main (high) stream and its sub (low) stream. */
    const val STREAM_MAIN = "nursery"
    const val STREAM_SMALL = "nursery_sd"
}

/** The go2rtc default ports. They are go2rtc's defaults, not the owner's setup. */
object Go2rtc {
    const val RTSP_PORT = 8554
    const val API_PORT = 1984
}
