package cz.drabek.chuvicka.proto

import cz.drabek.chuvicka.parent.replaceHost
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraFullTest {
    @Test
    fun aFullCamera() {
        assertTrue(RtspClient.isCameraFull(453, closedBeforePlay = false, directCamera = true))
        assertTrue(RtspClient.isCameraFull(null, closedBeforePlay = true, directCamera = true))
    }

    @Test
    fun notAFullCamera() {
        assertFalse(RtspClient.isCameraFull(null, closedBeforePlay = true, directCamera = false))   // go2rtc, the baby phone
        assertFalse(RtspClient.isCameraFull(401, closedBeforePlay = false, directCamera = true))
        assertFalse(RtspClient.isCameraFull(null, closedBeforePlay = false, directCamera = true))
        assertFalse(RtspClient.isCameraFull(453, closedBeforePlay = false, directCamera = false))
    }

    @Test
    fun theMessage() {
        assertEquals("Kameru teď sleduje příliš mnoho telefonů. Zkuste to za chvíli, nebo zavřete Chůvičku na jiném telefonu.",
            RtspClient.CameraFull().message)
    }

    @Test
    fun theNewHost() {
        assertEquals("rtsp://u:p@192.168.0.50:554/stream1", replaceHost("rtsp://u:p@192.168.0.197:554/stream1", "192.168.0.50"))
        assertEquals("rtsp://192.168.0.50:554/stream1", replaceHost("rtsp://192.168.0.197:554/stream1", "192.168.0.50"))
        assertEquals("rtsp://192.168.0.50/Streaming/Channels/101", replaceHost("rtsp://192.168.0.197/Streaming/Channels/101", "192.168.0.50"))
    }
}
