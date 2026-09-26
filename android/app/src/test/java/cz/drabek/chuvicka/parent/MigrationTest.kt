package cz.drabek.chuvicka.parent

import cz.drabek.chuvicka.Settings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/** The move from go2rtc to the camera directly: what go2rtc tells about the camera. */
class MigrationTest {
    private val streams = """
        {"nursery":{"producers":[{"type":"RTSP active producer","url":"rtsp://u%40x:p%3Ass@192.168.0.197:554/stream1","medias":["video, recvonly, H264"]}],"consumers":null},
         "nursery_sd":{"producers":[{"url":"rtsp://u%40x:p%3Ass@192.168.0.197:554/stream2#backchannel=0"}]},
         "other":{"producers":[{"url":"ffmpeg:nursery#audio=opus"}]}}
    """.trimIndent()

    private val config = """
        api:
          listen: ":1984"
        streams:
          # The Tapo in the nursery
          garden: rtsp://a:b@192.168.0.50:554/Streaming/Channels/101
          nursery:
            - rtsp://u%40x:p%3Ass@192.168.0.197:554/stream1
            - "ffmpeg:nursery#audio=opus"
          nursery_sd:
            - rtsp://u%40x:p%3Ass@192.168.0.197:554/stream2
        webrtc:
          candidates:
            - 192.168.0.136:8555
    """.trimIndent()

    private fun assertTapo(r: ServerMigration.Result?) {
        assertNotNull(r)
        r!!
        assertEquals("192.168.0.197", r.host)
        assertEquals(554, r.port)
        assertEquals("u@x", r.user)
        assertEquals("p:ss", r.password)
        assertEquals("stream1", r.mainPath)
        assertEquals("stream2", r.smallPath)
        assertEquals(Settings.CameraBrand.TAPO, r.brand)
    }

    @Test fun fromTheStreamList() = assertTapo(ServerMigration.parseStreams(streams, "nursery", "nursery_sd"))

    @Test fun fromTheConfig() = assertTapo(ServerMigration.parseConfig(config, "nursery", "nursery_sd"))

    @Test fun onlyFfmpegSources() {
        val json = """{"nursery":{"producers":[{"url":"ffmpeg:rtsp://x#video=h264"}]},"nursery_sd":{"producers":[]}}"""
        assertNull(ServerMigration.parseStreams(json, "nursery", "nursery_sd"))
        assertNull(ServerMigration.parseStreams("not json", "nursery", "nursery_sd"))
    }

    @Test fun hikvisionWithoutASubStream() {
        val r = ServerMigration.parseConfig(config, "garden", "missing")
        assertEquals(Settings.CameraBrand.HIKVISION, r?.brand)
        assertEquals("Streaming/Channels/101", r?.mainPath)
        assertNull(r?.smallPath)
        assertEquals("a", r?.user)
    }

    @Test fun dahuaQueryInJsonEscapes() {
        val json = """{"cam":{"producers":[{"url":"rtsp:\/\/admin:x@10.0.0.9\/cam\/realmonitor?channel=1&subtype=0"}]}}"""
        val r = ServerMigration.parseStreams(json, "cam", "cam")
        assertEquals(Settings.CameraBrand.DAHUA, r?.brand)
        assertEquals("cam/realmonitor?channel=1&subtype=0", r?.mainPath)
        assertEquals(554, r?.port)
        assertNull(r?.smallPath)
    }
}
