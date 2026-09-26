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
}
