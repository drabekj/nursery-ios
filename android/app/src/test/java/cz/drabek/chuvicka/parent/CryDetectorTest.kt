package cz.drabek.chuvicka.parent

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The pure parts of the cry classifier: 8 to 16 kHz, the window, the scores to a verdict. */
class CryDetectorTest {
    @Test
    fun upsampleInterpolatesBetweenSamples() {
        val out = FloatArray(6)
        val last = Yamnet.upsample(floatArrayOf(0.2f, 0.4f, -0.4f), 3, 0f, out)
        assertArrayEquals(floatArrayOf(0.1f, 0.2f, 0.3f, 0.4f, 0f, -0.4f), out, 1e-6f)
        assertEquals(-0.4f, last, 0f)
    }

    @Test
    fun upsampleContinuesFromTheLastPacket() {
        val out = FloatArray(4)
        Yamnet.upsample(floatArrayOf(1f, 1f), 2, -1f, out)
        assertArrayEquals(floatArrayOf(0f, 1f, 1f, 1f), out, 1e-6f)
    }

    @Test
    fun windowComesEveryHalfSecond() {
        val starts = mutableListOf<Float>()
        val w = SlidingWindow(Yamnet.WINDOW, Yamnet.HOP) { starts.add(it[0]); assertEquals(Yamnet.WINDOW, it.size) }
        // 2 s of 16 kHz sound in 20 ms packets (320 samples); each sample is its own index.
        var n = 0
        repeat(100) {
            val packet = FloatArray(320) { (n + it).toFloat() }
            n += 320
            w.add(packet, packet.size)
        }
        // Full at 15600, then every 8000: 15600, 23600, 31600 (of 32000).
        assertEquals(listOf(0f, 8000f, 16000f), starts)
    }

    @Test
    fun windowClearStartsOver() {
        var count = 0
        val w = SlidingWindow(10, 5) { count++ }
        w.add(FloatArray(8), 8)
        w.clear()
        w.add(FloatArray(8), 8)
        assertEquals(0, count)
        w.add(FloatArray(2), 2)
        assertEquals(1, count)
    }

    private fun scores(vararg pairs: Pair<Int, Float>) = FloatArray(Yamnet.CLASSES) { 0.01f }.also { s ->
        for ((i, v) in pairs) s[i] = v
    }

    private val labels = List(Yamnet.CLASSES) { "c$it" }

    @Test
    fun babyCryAboveItsThresholdIsACry() {
        assertEquals(CryVerdict.Cry(0.35f), Yamnet.verdict(scores(20 to 0.35f, 0 to 0.6f), labels))
        assertEquals(CryVerdict.Cry(0.82f), Yamnet.verdict(scores(20 to 0.82f), labels))
    }

    @Test
    fun cryingSobbingNeedsHalf() {
        assertEquals(CryVerdict.Cry(0.5f), Yamnet.verdict(scores(19 to 0.5f, 20 to 0.2f), labels))
        assertEquals(CryVerdict.Other("c19", 0.49f), Yamnet.verdict(scores(19 to 0.49f, 20 to 0.2f), labels))
    }

    @Test
    fun otherwiseTheBestClass() {
        assertEquals(CryVerdict.Other("c69", 0.7f), Yamnet.verdict(scores(69 to 0.7f, 20 to 0.34f), labels))
        assertEquals(CryVerdict.Other("class 518", 0.9f), Yamnet.verdict(scores(518 to 0.9f), emptyList()))
    }

    @Test
    fun everyCryVerdictPassesTheMachine() {
        // Monitor builds the machine with cryConfidence = BABY_CRY_MIN: the verdict rule decides alone.
        for (s in listOf(scores(20 to 0.35f), scores(19 to 0.5f))) {
            val v = Yamnet.verdict(s, labels) as CryVerdict.Cry
            assertTrue(v.confidence >= Yamnet.BABY_CRY_MIN)
        }
    }

    @Test
    fun logLines() {
        assertEquals("cry: baby_cry 0.61", Yamnet.describe(CryVerdict.Cry(0.61f), scores(20 to 0.61f)))
        assertEquals("cry: crying_sobbing 0.55", Yamnet.describe(CryVerdict.Cry(0.55f), scores(19 to 0.55f)))
        assertEquals("cry: other Speech 0.40", Yamnet.describe(CryVerdict.Other("Speech", 0.4f), scores()))
    }

    @Test
    fun labelsOfTheBundledClassMap() {
        val csv = File("src/main/assets/yamnet_class_map.csv").readText()
        val l = Yamnet.labels(csv)
        assertEquals(Yamnet.CLASSES, l.size)
        assertEquals("Speech", l[0])
        assertEquals("Crying, sobbing", l[Yamnet.CRYING])
        assertEquals("Baby cry, infant cry", l[Yamnet.BABY_CRY])
    }
}
