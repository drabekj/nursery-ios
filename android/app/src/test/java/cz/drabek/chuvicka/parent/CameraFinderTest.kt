package cz.drabek.chuvicka.parent

import cz.drabek.chuvicka.Settings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The camera search: which addresses are home, and what a camera's answer says about it. */
class CameraFinderTest {
    @Test fun privateAddresses() {
        assertTrue(CameraFinder.isPrivate("192.168.0.12"))
        assertTrue(CameraFinder.isPrivate("10.0.0.5"))
        assertTrue(CameraFinder.isPrivate("172.20.1.1"))
        assertFalse(CameraFinder.isPrivate("172.32.1.1"))
        assertFalse(CameraFinder.isPrivate("100.104.188.72"))
    }

    @Test fun brandFromRealm() {
        val tapo = "RTSP/1.0 401 Unauthorized\r\nCSeq: 1\r\nWWW-Authenticate: Digest realm=\"TP-LINK IP-Camera\", nonce=\"abc\"\r\n\r\n"
        assertEquals(Settings.CameraBrand.TAPO, CameraFinder.brand(tapo))
        assertEquals("Tapo", CameraFinder.label(tapo))
        val dahua = "RTSP/1.0 401 Unauthorized\r\nWWW-Authenticate: Digest realm=\"Login to 4K0123PAZ\", nonce=\"x\"\r\n\r\n"
        assertEquals(Settings.CameraBrand.DAHUA, CameraFinder.brand(dahua))
    }

    @Test fun unknownDeviceKeepsItsName() {
        val other = "RTSP/1.0 404 Not Found\r\nCSeq: 1\r\nServer: Rtsp Server 3.0\r\n\r\n"
        assertNull(CameraFinder.brand(other))
        assertEquals("Rtsp Server 3.0", CameraFinder.label(other))
        assertNull(CameraFinder.label("RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n"))
    }

    @Test fun wifiWinsOverHotspot() {
        assertEquals("192.168.0.12" to "192.168.0", CameraFinder.pick(listOf("ap0" to "192.168.43.1", "wlan0" to "192.168.0.12")))
    }

    @Test fun hotspotWinsOverMobileData() {
        assertEquals("192.168.43.1" to "192.168.43", CameraFinder.pick(listOf("rmnet0" to "10.12.0.3", "ap0" to "192.168.43.1")))
    }

    @Test fun anyOtherPrivateAddress() {
        assertEquals("10.0.0.5" to "10.0.0", CameraFinder.pick(listOf("eth0" to "10.0.0.5")))
    }

    @Test fun neverMobileData() {
        assertNull(CameraFinder.pick(listOf("rmnet0" to "10.12.0.3")))
        assertNull(CameraFinder.pick(listOf("ccmni1" to "10.20.0.3", "pdp0" to "192.168.1.3")))
    }

    @Test fun neverTheVpn() {
        assertEquals("10.0.0.5" to "10.0.0", CameraFinder.pick(listOf("tun0" to "100.100.1.1", "eth0" to "10.0.0.5")))
        assertNull(CameraFinder.pick(listOf("tailscale0" to "10.1.2.3", "tun0" to "100.100.1.1")))
    }

    @Test fun anotherHostKeepsTheLogin() {
        assertEquals("rtsp://u%40x:p%3Ass@192.168.0.44:554/stream1",
            CameraFinder.withHost("rtsp://u%40x:p%3Ass@192.168.0.197:554/stream1", "192.168.0.44"))
        assertEquals("rtsp://192.168.0.44/cam/realmonitor?channel=1&subtype=0",
            CameraFinder.withHost("rtsp://192.168.0.197/cam/realmonitor?channel=1&subtype=0", "192.168.0.44"))
        assertEquals("192.168.0.197", CameraFinder.hostOf("rtsp://u:p@192.168.0.197:554/stream1"))
    }
}
