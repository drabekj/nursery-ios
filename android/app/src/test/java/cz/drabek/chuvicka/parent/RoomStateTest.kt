package cz.drabek.chuvicka.parent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The word on the screen, from the signals: Připojuji, Klid, Ozývá se, Pláče, Nehlídá.
 *  The same cases as RoomStateTests.swift. */
class RoomStateTest {
    private val t0 = 1_000_000_000L
    private fun at(s: Double) = t0 + (s * 1000).toLong()
    private fun at(s: Int) = at(s.toDouble())

    private fun input(heard: Boolean = true, everHeard: Boolean = true, event: Boolean = false, seconds: Double = 0.0,
                      peak: Float = 0f, level: Float = 0f, classifier: Boolean = true) =
        RoomStateMachine.Input(heard = heard, everHeard = everHeard, eventRunning = event, eventSeconds = seconds,
            eventPeak = peak, level = level, classifierAvailable = classifier)

    private val cry = CryVerdict.Cry(0.9f)

    @Test
    fun startsConnectingThenCalm() {
        val m = RoomStateMachine()
        assertEquals(RoomState.CONNECTING, m.update(input(heard = false, everHeard = false), at(0)))
        assertEquals(RoomState.CONNECTING, m.update(input(heard = false, everHeard = false), at(19)))
        assertEquals(RoomState.CALM, m.update(input(), at(20)))
        assertEquals(at(20), m.since)
    }

    @Test
    fun neverHeardBecomesLostAfter20s() {
        val m = RoomStateMachine()
        m.update(input(heard = false, everHeard = false), at(0))
        assertEquals(RoomState.CONNECTING, m.update(input(heard = false, everHeard = true), at(5)))
        assertEquals(RoomState.CONNECTING, m.update(input(heard = false, everHeard = true), at(24)))
        assertEquals(RoomState.LOST, m.update(input(heard = false, everHeard = true), at(25)))
    }

    @Test
    fun gapKeepsTheLastStateThenLost() {
        val m = RoomStateMachine()
        m.update(input(), at(0))
        assertEquals(RoomState.CALM, m.update(input(heard = false), at(1)))
        assertEquals(RoomState.CALM, m.update(input(heard = false), at(20)))
        assertEquals(RoomState.LOST, m.update(input(heard = false), at(21)))
        assertEquals(RoomState.CALM, m.update(input(), at(22)))
    }

    @Test
    fun soundWithoutCryVerdicts() {
        val m = RoomStateMachine()
        m.update(input(), at(0))
        assertEquals(RoomState.SOUND, m.update(input(event = true), at(1)))
        m.classified(CryVerdict.Other("dog", 0.8f))
        m.classified(CryVerdict.Cry(0.3f))
        m.classified(CryVerdict.Other("speech", 0.6f))
        assertEquals(RoomState.SOUND, m.update(input(event = true), at(2)))
    }

    @Test
    fun twoOfThreeCryVerdictsGiveCry() {
        val m = RoomStateMachine()
        m.update(input(), at(0))
        m.update(input(event = true), at(1))
        m.classified(cry)
        assertEquals(RoomState.SOUND, m.update(input(event = true), at(1.5)))
        m.classified(CryVerdict.Other("speech", 0.5f))
        m.classified(CryVerdict.Cry(0.6f))
        assertEquals(RoomState.CRY, m.update(input(event = true), at(2)))
        assertEquals(at(2), m.since)
    }

    @Test
    fun cryHoldsThroughAPauseAndEndsWithTheEvent() {
        val m = RoomStateMachine()
        m.update(input(), at(0))
        m.update(input(event = true), at(1))
        m.classified(cry); m.classified(cry)
        assertEquals(RoomState.CRY, m.update(input(event = true), at(2)))
        // The baby breathes: three "other" verdicts. Still Pláče for 15 s.
        repeat(3) { m.classified(CryVerdict.Other("silence", 0.9f)) }
        assertEquals(RoomState.CRY, m.update(input(event = true), at(10)))
        assertEquals(RoomState.CRY, m.update(input(event = true), at(16.5)))     // The 15 s hold from 2 s runs to 17 s.
        assertEquals(RoomState.SOUND, m.update(input(event = true), at(17.5)))
        assertEquals(RoomState.CALM, m.update(input(event = false), at(18)))
    }

    @Test
    fun cryEndsTenSecondsAfterTheLastVerdict() {
        val m = RoomStateMachine()
        m.update(input(), at(0))
        m.update(input(event = true), at(1))
        m.classified(cry); m.classified(cry)
        m.update(input(event = true), at(2))
        m.classified(cry)
        m.update(input(event = true), at(20))            // A cry verdict again at 20 s.
        repeat(3) { m.classified(CryVerdict.Other("x", 1f)) }
        assertEquals(RoomState.CRY, m.update(input(event = true), at(29)))
        assertEquals(RoomState.SOUND, m.update(input(event = true), at(30.5)))
    }

    @Test
    fun eventEndClearsVerdicts() {
        val m = RoomStateMachine()
        m.update(input(), at(0))
        m.update(input(event = true), at(1))
        m.classified(cry); m.classified(cry)
        m.update(input(event = true), at(2))
        assertEquals(RoomState.CALM, m.update(input(event = false), at(30)))
        assertTrue(m.verdicts.isEmpty())
        assertEquals(RoomState.SOUND, m.update(input(event = true), at(40)))
    }

    @Test
    fun loudnessRuleWithoutClassifier() {
        val m = RoomStateMachine()
        m.update(input(classifier = false), at(0))
        // Loud ticks at 2 Hz: 12 ticks = 6 s of loud sound within 12 s.
        var state = RoomState.CALM
        for (i in 0 until 12) {
            state = m.update(input(event = true, seconds = i / 2.0, level = 0.7f, classifier = false), at(1 + i / 2.0))
        }
        assertEquals(RoomState.CRY, state)
        // A quieter loud spell does not count.
        val q = RoomStateMachine()
        q.update(input(classifier = false), at(0))
        for (i in 0 until 12) {
            state = q.update(input(event = true, seconds = i / 2.0, level = 0.3f, classifier = false), at(1 + i / 2.0))
        }
        assertEquals(RoomState.SOUND, state)
    }

    @Test
    fun longLoudEventWithoutClassifier() {
        val m = RoomStateMachine()
        m.update(input(classifier = false), at(0))
        assertEquals(RoomState.SOUND, m.update(input(event = true, seconds = 11.0, peak = 0.9f, level = 0.2f, classifier = false), at(12)))
        assertEquals(RoomState.CRY, m.update(input(event = true, seconds = 12.0, peak = 0.9f, level = 0.2f, classifier = false), at(13)))
    }

    @Test
    fun classifierVerdictsIgnoreLoudnessRule() {
        val m = RoomStateMachine()
        m.update(input(), at(0))
        // Loud and long, but the classifier says vacuum cleaner: Ozývá se, not Pláče.
        var state = RoomState.CALM
        for (i in 0 until 30) {
            m.classified(CryVerdict.Other("vacuum_cleaner", 0.9f))
            state = m.update(input(event = true, seconds = i / 2.0, peak = 0.95f, level = 0.9f), at(1 + i / 2.0))
        }
        assertEquals(RoomState.SOUND, state)
    }

    @Test
    fun titles() {
        assertEquals("Připojuji…", RoomState.CONNECTING.title)
        assertEquals("Klid", RoomState.CALM.title)
        assertEquals("Ozývá se", RoomState.SOUND.title)
        assertEquals("Pláče", RoomState.CRY.title)
        assertEquals("Nehlídá", RoomState.LOST.title)
    }
}
