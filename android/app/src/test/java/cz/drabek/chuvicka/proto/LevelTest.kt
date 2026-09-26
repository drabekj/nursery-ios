package cz.drabek.chuvicka.proto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.pow

class LevelTest {
    private fun rmsAt(dbfs: Double) = 10.0.pow(dbfs / 20)

    @Test
    fun silenceIsZero() {
        assertEquals(0f, levelFromRms(0.0), 0f)
        assertEquals(0f, levelFromRms(-1.0), 0f)
        assertEquals(0f, levelFromRms(rmsAt(-80.0)), 0f)
        assertEquals(0f, levelFromRms(rmsAt(-58.0)), 1e-5f)
    }

    @Test
    fun aCryIsOne() {
        assertEquals(1f, levelFromRms(rmsAt(-12.0)), 1e-5f)
        assertEquals(1f, levelFromRms(1.0), 0f)            // Clamped.
        assertEquals(1f, levelFromRms(100.0), 0f)
    }

    @Test
    fun linearInDecibels() {
        assertEquals(0.5f, levelFromRms(rmsAt(-35.0)), 1e-5f)      // Halfway from -58 to -12.
    }

    @Test
    fun monotonic() {
        var last = -1f
        var rms = 1e-7
        while (rms < 2.0) {
            val level = levelFromRms(rms)
            assertTrue("rms $rms", level >= last)
            assertTrue(level in 0f..1f)
            last = level
            rms *= 1.1
        }
    }
}
