package cz.drabek.chuvicka.parent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StreamPolicyTest {
    private val big = StreamPolicy.Inputs(
        wantsDetail = true, soundOnly = false, thermalHot = false, powerSave = false,
        detailStream = "rtsp://pi:8554/nursery", everydayStream = "rtsp://pi:8554/nursery_sd",
    )

    @Test
    fun aBigPictureGetsTheDetailStream() {
        assertTrue(StreamPolicy.detail(big))
        assertEquals("rtsp://pi:8554/nursery", StreamPolicy.stream(big))
    }

    @Test
    fun eachReasonGivesTheEverydayStream() {
        for (i in listOf(big.copy(wantsDetail = false), big.copy(soundOnly = true),
                         big.copy(thermalHot = true), big.copy(powerSave = true))) {
            assertFalse(i.toString(), StreamPolicy.detail(i))
            assertEquals("rtsp://pi:8554/nursery_sd", StreamPolicy.stream(i))
        }
    }

    @Test
    fun equalStreamsNeverGiveDetail() {
        val same = big.copy(detailStream = "rtsp://cam/stream1", everydayStream = "rtsp://cam/stream1")
        assertFalse(StreamPolicy.detail(same))
        assertEquals("rtsp://cam/stream1", StreamPolicy.stream(same))
    }
}
