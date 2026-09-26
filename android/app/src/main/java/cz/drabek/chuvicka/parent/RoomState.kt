package cz.drabek.chuvicka.parent

/**
 * What the room is doing, in one word. The big word on the screen, the colour of the field,
 * the title of a notification. It is derived twice a second from three things the monitor
 * already has: the sound status, the sound event (`soundNow`), and the cry classifier.
 * The same states and rules as `RoomState.swift` of the iOS app.
 *
 * The words are honest: "Klid" means the room is quiet, not that the baby sleeps. "Pláče" means
 * the classifier heard a baby cry during a loud stretch; without a classifier it means "loud for
 * a while", and Nápověda says so.
 */
enum class RoomState(val title: String) {
    /** The start: the app has not heard the room yet. */
    CONNECTING("Připojuji…"),
    /** Quiet, or nothing above the noise floor. */
    CALM("Klid"),
    /** A sound event runs: something is louder than the room. A sigh, a dog, a door, a cry that
     *  the classifier has not confirmed yet. */
    SOUND("Ozývá se"),
    /** A baby cry, confirmed by the classifier (or by loudness and duration without one). */
    CRY("Pláče"),
    /** No sound for 20 s: the app does not hear the room. */
    LOST("Nehlídá"),
}

/** One verdict of the cry classifier, for one window of sound (about one second). */
sealed interface CryVerdict {
    /** The classifier said "baby cry" with this confidence (0...1). */
    data class Cry(val confidence: Float) : CryVerdict
    /** The classifier heard something else (its label, for the log). */
    data class Other(val label: String, val confidence: Float) : CryVerdict
}

/**
 * The rules that turn the signals into a [RoomState]. Pure: no clock of its own, no views.
 * Feed it at 2 Hz with [update], and the verdicts of the classifier as they arrive.
 * The times are milliseconds (System.currentTimeMillis), the durations are seconds.
 */
class RoomStateMachine(
    /** The classifier must say "cry" with at least this confidence... */
    val cryConfidence: Float = 0.5f,
    /** ...in at least this many of the last [windowCount] verdicts. */
    val cryVotes: Int = 2,
    val windowCount: Int = 3,
    /** "Pláče" stays at least this long, so the pauses of a crying baby do not flip the word... */
    val cryHold: Double = 15.0,
    /** ...and it ends this long after the last cry verdict. */
    val cryRelease: Double = 10.0,
    /** "Nehlídá" after this long without sound. The same time as the loss notification. */
    val lostAfter: Double = 20.0,
    /** The loudness rule without a classifier: this many loud seconds within [loudWindow]... */
    val loudSeconds: Double = 6.0,
    val loudWindow: Double = 12.0,
    /** ...or an event this long with a peak this high. The same rule as the iOS episode kind. */
    val longEvent: Double = 12.0,
    val loudPeak: Float = 0.78f,
) {
    /** The signals at one moment. */
    data class Input(
        /** The app hears the room now (live or muted). */
        val heard: Boolean,
        /** The app has heard the room at least once since the start. */
        val everHeard: Boolean,
        /** A sound event runs (`soundNow`). */
        val eventRunning: Boolean,
        /** Seconds of the running event, 0 without one. */
        val eventSeconds: Double = 0.0,
        /** The peak level of the running event, 0...1. */
        val eventPeak: Float = 0f,
        /** The smoothed level now, 0...1. */
        val level: Float = 0f,
        /** The level that counts as loud. */
        val loudLevel: Float = 0.45f,
        /** The classifier can run (a model is loaded). Without one the loudness rule decides. */
        val classifierAvailable: Boolean,
    )

    var state: RoomState = RoomState.CONNECTING
        private set
    /** When the state last changed. */
    var since: Long? = null
        private set
    private val recent = ArrayList<CryVerdict>()
    /** The last verdicts, newest last. Cleared when the event ends. */
    val verdicts: List<CryVerdict> get() = recent
    private var lostSince: Long? = null
    private var lastCry: Long? = null
    private val loudTicks = ArrayDeque<Long>()

    /** A verdict of the classifier. It counts only while a sound event runs. */
    fun classified(verdict: CryVerdict) {
        recent.add(verdict)
        while (recent.size > windowCount) recent.removeAt(0)
    }

    /** The signals at [now]. Returns the state, changed or not. */
    fun update(input: Input, now: Long): RoomState {
        val next: RoomState
        if (!input.heard) {
            if (!input.everHeard) {
                next = RoomState.CONNECTING
            } else {
                if (lostSince == null) lostSince = now
                val lostFor = seconds(now, lostSince ?: now)
                // The last state stays for the first seconds of a gap. A ribbon says "Připojuji…".
                next = if (lostFor >= lostAfter) RoomState.LOST
                    else if (state == RoomState.CONNECTING) RoomState.CONNECTING else state
            }
        } else {
            lostSince = null
            if (input.eventRunning) {
                trackLoud(input, now)
                val crying = if (input.classifierAvailable) cryByClassifier() else cryByLoudness(input)
                if (crying) lastCry = now
                val since = since
                val lastCry = lastCry
                next = if (state == RoomState.CRY && since != null && lastCry != null) {
                    val holding = seconds(now, since) < cryHold || seconds(now, lastCry) < cryRelease
                    if (crying || holding) RoomState.CRY else RoomState.SOUND
                } else {
                    if (crying) RoomState.CRY else RoomState.SOUND
                }
            } else {
                recent.clear()
                loudTicks.clear()
                lastCry = null
                next = RoomState.CALM
            }
        }
        if (next != state) {
            state = next
            since = now
        }
        return state
    }

    private fun cryByClassifier(): Boolean =
        recent.count { it is CryVerdict.Cry && it.confidence >= cryConfidence } >= cryVotes

    private fun trackLoud(input: Input, now: Long) {
        if (input.level >= input.loudLevel) loudTicks.addLast(now)
        while (loudTicks.isNotEmpty() && seconds(now, loudTicks.first()) > loudWindow) loudTicks.removeFirst()
    }

    private fun cryByLoudness(input: Input): Boolean {
        // The ticks come at 2 Hz: each one is half a second of loud sound.
        val loud = loudTicks.size * 0.5 >= loudSeconds
        val long = input.eventSeconds >= longEvent && input.eventPeak >= loudPeak
        return loud || long
    }

    private fun seconds(now: Long, then: Long) = (now - then) / 1000.0
}
