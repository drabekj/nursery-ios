package cz.drabek.chuvicka.proto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class RtspUrlTest {
    @Test
    fun go2rtcUrl() {
        assertEquals(RtspClient.Endpoint("192.168.0.136", 8554, "", ""), RtspClient.parse("rtsp://192.168.0.136:8554/nursery"))
    }

    @Test
    fun thePortIs554ByDefault() {
        assertEquals(554, RtspClient.parse("rtsp://192.168.0.50/stream1").port)
    }

    @Test
    fun theLoginIsPercentDecoded() {
        // Settings.withCredentials writes the user and the password percent-encoded.
        val e = RtspClient.parse("rtsp://admin:p%40ss%3Aw%20rd%2B1@192.168.0.50:554/Streaming/Channels/101")
        assertEquals("192.168.0.50", e.host)
        assertEquals(554, e.port)
        assertEquals("admin", e.user)
        assertEquals("p@ss:w rd+1", e.password)
    }

    @Test
    fun aUserWithNoPassword() {
        val e = RtspClient.parse("rtsp://admin@192.168.0.50/stream1")
        assertEquals("admin", e.user)
        assertEquals("", e.password)
    }

    @Test
    fun anEmptyPassword() {
        val e = RtspClient.parse("rtsp://admin:@192.168.0.50/stream1")
        assertEquals("admin", e.user)
        assertEquals("", e.password)
    }

    @Test
    fun rejectsABadUrl() {
        assertThrows(RtspClient.Failure::class.java) { RtspClient.parse("rtsp://bad host/stream1") }
        assertThrows(RtspClient.Failure::class.java) { RtspClient.parse("rtsp:///stream1") }
    }

    @Test
    fun theRequestUrlHasNoLogin() {
        // The path and the query stay, the login goes only in the Authorization header.
        assertEquals("rtsp://192.168.0.50:554/cam/realmonitor?channel=1&subtype=0",
            RtspClient.withoutCredentials("rtsp://admin:secret@192.168.0.50:554/cam/realmonitor?channel=1&subtype=0"))
        assertEquals("RTSP://192.168.0.50/stream1", RtspClient.withoutCredentials("RTSP://u:p@192.168.0.50/stream1"))
        assertEquals("rtsp://192.168.0.136:8554/nursery", RtspClient.withoutCredentials("rtsp://192.168.0.136:8554/nursery"))
        // An "@" in the path is not a login.
        assertEquals("rtsp://h/a@b", RtspClient.withoutCredentials("rtsp://h/a@b"))
    }

    @Test
    fun tailscaleIs100_64Slash10() {
        assertTrue(RtspClient.isTailscale("100.64.0.1"))
        assertTrue(RtspClient.isTailscale("100.104.188.72"))
        assertTrue(RtspClient.isTailscale("100.127.255.255"))
        assertFalse(RtspClient.isTailscale("100.63.255.255"))
        assertFalse(RtspClient.isTailscale("100.128.0.0"))
        assertFalse(RtspClient.isTailscale("192.168.0.1"))
        assertFalse(RtspClient.isTailscale("10.64.0.1"))
    }

    @Test
    fun tailscaleNeedsFourNumbers() {
        assertFalse(RtspClient.isTailscale("100.64.0"))
        assertFalse(RtspClient.isTailscale("100.64.x.1"))
        assertFalse(RtspClient.isTailscale("100.64.0.1:8555"))      // Not with the port.
        assertFalse(RtspClient.isTailscale("chuvicka"))
        assertFalse(RtspClient.isTailscale(""))
    }
}
