package cz.drabek.chuvicka.proto

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class SdpTest {
    // What go2rtc sends for the Tapo camera: H.264 and PCMA, CRLF line ends, no Content-Base.
    private val go2rtc = listOf(
        "v=0",
        "o=- 0 0 IN IP4 0.0.0.0",
        "s=-",
        "t=0 0",
        "m=video 0 RTP/AVP 96",
        "a=rtpmap:96 H264/90000",
        "a=fmtp:96 packetization-mode=1;sprop-parameter-sets=Z2QAKKzZQHgCJ+XARAAAAwAEAAADAPA8YMZY,aOvjyyLA;profile-level-id=640028",
        "a=control:trackID=0",
        "m=audio 0 RTP/AVP 8",
        "a=rtpmap:8 PCMA/8000",
        "a=control:trackID=1",
        "",
    ).joinToString("\r\n")

    @Test
    fun parsesTheTracksOfGo2rtc() {
        val tracks = Sdp.parse(go2rtc)
        assertEquals(2, tracks.size)

        val video = tracks[0]
        assertEquals("video", video.kind)
        assertEquals(96, video.payloadType)
        assertEquals("H264", video.codec)
        assertEquals(90000, video.clockRate)
        assertEquals("trackID=0", video.control)
        assertEquals("1", video.fmtp["packetization-mode"])
        assertEquals("640028", video.fmtp["profile-level-id"])

        val audio = tracks[1]
        assertEquals("audio", audio.kind)
        assertEquals(8, audio.payloadType)
        assertEquals("PCMA", audio.codec)
        assertEquals(8000, audio.clockRate)
        assertEquals("trackID=1", audio.control)
        assertNull(audio.h264ParameterSets)
    }

    @Test
    fun decodesTheParameterSets() {
        val sets = Sdp.parse(go2rtc)[0].h264ParameterSets
        assertNotNull(sets)
        val (sps, pps) = sets!!
        assertArrayEquals(hex("67640028acd940780227e5c044000003000400000300f03c60c658"), sps)
        assertArrayEquals(hex("68ebe3cb22c0"), pps)
    }

    @Test
    fun keepsTheBase64PaddingInFmtp() {
        // Only the first "=" splits the key from the value.
        val sdp = "m=video 0 RTP/AVP 96\na=rtpmap:96 H264/90000\na=fmtp:96 sprop-parameter-sets=Z0IAH5WoFAFuQA==,aM48gA==\n"
        val track = Sdp.parse(sdp)[0]
        assertEquals("Z0IAH5WoFAFuQA==,aM48gA==", track.fmtp["sprop-parameter-sets"])
        val (sps, pps) = track.h264ParameterSets!!
        assertEquals(7, sps[0].toInt() and 0x1F)
        assertEquals(8, pps[0].toInt() and 0x1F)
    }

    @Test
    fun needsBothParameterSets() {
        val sdp = "m=video 0 RTP/AVP 96\na=rtpmap:96 H264/90000\na=fmtp:96 sprop-parameter-sets=Z0IAH5WoFAFuQA==\n"
        assertNull(Sdp.parse(sdp)[0].h264ParameterSets)
    }

    @Test
    fun knowsTheStaticPayloadTypes() {
        // PCMU (0) and PCMA (8) may come with no rtpmap line.
        val tracks = Sdp.parse("m=audio 0 RTP/AVP 0\na=control:a\nm=audio 0 RTP/AVP 8\n")
        assertEquals("PCMU", tracks[0].codec)
        assertEquals(8000, tracks[0].clockRate)
        assertEquals("a", tracks[0].control)
        assertEquals("PCMA", tracks[1].codec)
        assertEquals(8000, tracks[1].clockRate)
        assertEquals("", tracks[1].control)
    }

    @Test
    fun skipsAMediaLineWithNoPayloadType() {
        val tracks = Sdp.parse("m=application 0 RTP/AVP\nm=audio 0 RTP/AVP 8\n")
        assertEquals(1, tracks.size)
        assertEquals("audio", tracks[0].kind)
    }

    @Test
    fun theUsableTracks() {
        val tracks = Sdp.parse(go2rtc)
        assertEquals(true, RtspClient.isUsable(tracks[0]))
        assertEquals(true, RtspClient.isUsable(tracks[1]))
        val opus = Sdp.parse("m=audio 0 RTP/AVP 111\na=rtpmap:111 opus/48000/2\n")[0]
        assertEquals("OPUS", opus.codec)
        assertEquals(false, RtspClient.isUsable(opus))
    }

    @Test
    fun controlUrl() {
        val base = "rtsp://192.168.0.136:8554/nursery"
        assertEquals(base, Sdp.controlUrl(base, ""))
        assertEquals(base, Sdp.controlUrl(base, "*"))
        assertEquals("$base/trackID=0", Sdp.controlUrl(base, "trackID=0"))
        assertEquals("rtsp://h/live/trackID=1", Sdp.controlUrl("rtsp://h/live/", "trackID=1"))
        assertEquals("rtsp://other/x/track1", Sdp.controlUrl(base, "rtsp://other/x/track1"))
        assertEquals("RTSP://other/x/track1", Sdp.controlUrl(base, "RTSP://other/x/track1"))
    }

    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(2 * it, 2 * it + 2).toInt(16).toByte() }
}
