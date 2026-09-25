package cz.drabek.chuvicka.parent

import android.content.Context
import android.media.AudioManager
import cz.drabek.chuvicka.App
import cz.drabek.chuvicka.Log
import cz.drabek.chuvicka.Settings
import cz.drabek.chuvicka.proto.AccessUnit
import cz.drabek.chuvicka.proto.G711
import cz.drabek.chuvicka.proto.H264Depacketizer
import cz.drabek.chuvicka.proto.RtpPacket
import cz.drabek.chuvicka.proto.RtspClient
import cz.drabek.chuvicka.proto.levelFromRms
import kotlinx.coroutines.flow.MutableStateFlow
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.max
import kotlin.math.sqrt

/** The room in words. The same levels and words as the iOS app. */
enum class RoomLevel(val title: String) {
    QUIET("Ticho"), SOME("Slabé zvuky"), LOUD("Hlasitý zvuk"), VERY_LOUD("Velmi hlasitý zvuk");
    companion object {
        fun of(v: Float) = when { v < 0.15f -> QUIET; v < 0.45f -> SOME; v < 0.75f -> LOUD; else -> VERY_LOUD }
    }
}

enum class SoundStatus(val title: String) {
    LISTENING("Živý zvuk"), SILENT("Tichý režim"), CONNECTING("Připojování…"), LOST("Zvuk vypadl"), MUTED("Zvuk vypnut")
}

enum class SoundMode(val title: String) { LIVE("Živý zvuk"), SILENT("Tichý režim"), OFF("Vypnuto") }

sealed interface Connection {
    data object Idle : Connection
    data object Connecting : Connection
    data object Live : Connection
    data class Retrying(val why: String, val failures: Int) : Connection
}

/**
 * The parent's monitor: the connection, the sound, the level, and the state for the screen.
 * The foreground service owns its life, so it runs also with the screen off.
 * One thread holds the connection and reconnects with a growing pause (1, 2, 4, 8 s).
 */
object Monitor {
    val connection = MutableStateFlow<Connection>(Connection.Idle)
    val status = MutableStateFlow(SoundStatus.CONNECTING)
    val mode = MutableStateFlow(SoundMode.LIVE)
    val roomLevel = MutableStateFlow(RoomLevel.QUIET)
    val history = MutableStateFlow(List(60) { 0f })
    val pictureLive = MutableStateFlow(false)
    val videoSize = MutableStateFlow(16 to 9)
    val volume = MutableStateFlow(1f)                 // The phone's media volume, 0...1.
    val soundNow = MutableStateFlow(false)
    val lastSound = MutableStateFlow<Long?>(null)
    /** Night mode: the picture is not needed. */
    val night = MutableStateFlow(false)

    /** The screen's video view, while it shows. */
    @Volatile var videoSink: ((AccessUnit, H264Depacketizer) -> Unit)? = null

    private lateinit var context: Context
    private var thread: Thread? = null
    @Volatile private var running = false
    @Volatile private var client: RtspClient? = null
    /** A reconnect on purpose (a new view, a new source) is not a failure, and it needs no pause. */
    @Volatile private var intentional = false
    @Volatile private var peak = 0f
    @Volatile private var lastAudio = 0L
    @Volatile private var lastVideo = 0L
    private var player: AudioPlayer? = null
    private var smoothed = 0f
    private var everHeard = false
    private var lostSince: Long? = null
    private var alerted = false
    private var louderSince: Long? = null
    private var quieterSince: Long? = null
    private var aboveSince: Long? = null
    private var belowSince: Long? = null

    val soundOnly get() = Settings.soundView.value || night.value

    fun start(context: Context) {
        if (running) return
        this.context = context.applicationContext
        running = true
        player = AudioPlayer().also { it.gainDb = Settings.loudness.value.decibels }
        thread = Thread({ loop() }, "monitor").apply { start() }
        Log.add("monitor on")
    }

    fun stop() {
        running = false
        client?.close()
        thread?.interrupt()
        player?.release()
        player = null
        connection.value = Connection.Idle
        Log.add("monitor off")
    }

    /** A new stream is needed: the view, the night mode, or the source changed. */
    fun reconnect(why: String) {
        Log.add("reconnect: $why")
        intentional = true
        client?.close()
    }

    fun setMode(m: SoundMode) {
        mode.value = m
        player?.muted = m != SoundMode.LIVE
    }

    fun setGain(db: Float) { player?.gainDb = db }

    // MARK: The connection

    private fun loop() {
        var pause = 1000L
        var failures = 0
        while (running) {
            if (App.demo) { demo(); return }
            if (connection.value !is Connection.Retrying) connection.value = Connection.Connecting
            try {
                val c = open()
                client = c
                val tracks = c.start()
                val video = tracks.firstOrNull { it.sdp.kind == "video" }
                val audio = tracks.firstOrNull { it.sdp.kind == "audio" }
                val depacketizer = H264Depacketizer()
                video?.sdp?.h264ParameterSets?.let { (s, p) -> depacketizer.setParameterSets(s, p) }
                val uLaw = audio?.sdp?.codec == "PCMU"
                Log.add("playing: ${tracks.joinToString { "${it.sdp.kind} ${it.sdp.codec}" }}")
                connection.value = Connection.Live
                pause = 1000L
                failures = 0
                c.play { channel, bytes ->
                    val p = RtpPacket.parse(bytes) ?: return@play
                    if (channel == video?.channel) {
                        val unit = depacketizer.push(p) ?: return@play
                        lastVideo = System.currentTimeMillis()
                        videoSink?.invoke(unit, depacketizer)
                    } else if (channel == audio?.channel) {
                        lastAudio = System.currentTimeMillis()
                        measure(p, uLaw)
                        player?.play(p.data, p.offset, p.length, uLaw)
                    }
                }
            } catch (e: Exception) {
                if (!running) break
                if (intentional) { intentional = false; continue }
                failures++
                val why = e.message ?: "Spojení se ukončilo."
                Log.add("connection ended: $why")
                connection.value = Connection.Retrying(why, failures)
                try { Thread.sleep(pause) } catch (_: InterruptedException) {}
                pause = minOf(pause * 2, 8000)
            } finally {
                client?.close()
                client = null
            }
        }
    }

    private fun open(): RtspClient {
        if (Settings.source.value == Settings.Source.CAMERA) return RtspClient.forUrl(Settings.cameraUrl(soundOnly))
        val name = Settings.babyName.value
        val code = Settings.babyCode.value
        if (name.isEmpty() || code.isEmpty()) throw IOException("Není spárovaný telefon u miminka. Spárujte ho v Nastavení.")
        val (host, port) = BabyFinder.resolve(context, name)
            ?: throw IOException("Telefon u miminka „$name“ není v síti. Běží na něm vysílání?")
        // The host in the URL is not used: the socket goes to the resolved address. The code is the path.
        return RtspClient("rtsp://chuvicka/$code" + if (soundOnly) "?audio" else "", host, port)
    }

    private fun measure(p: RtpPacket, uLaw: Boolean) {
        val table = if (uLaw) G711.uLaw else G711.aLaw
        var sum = 0.0
        for (i in 0 until p.length) {
            val s = table[p.data[p.offset + i].toInt() and 0xFF] / 32768.0
            sum += s * s
        }
        if (p.length > 0) peak = max(peak, levelFromRms(sqrt(sum / p.length)))
    }

    // MARK: The tick, 10 times a second, from the service

    fun tick(now: Long = System.currentTimeMillis()) {
        val raw = if (App.demo) demoLevel(now) else peak.also { peak = 0f }
        val target = if (mode.value != SoundMode.OFF) raw else 0f
        smoothed = if (target > smoothed) target else smoothed * 0.82f + target * 0.18f
        history.value = history.value.drop(1) + smoothed
        holdRoomLevel(RoomLevel.of(smoothed), now)
        detectSound(smoothed, now)

        pictureLive.value = now - lastVideo < 3000
        val heard = now - lastAudio < 3000
        if (heard) everHeard = true
        val s = when {
            mode.value == SoundMode.OFF -> SoundStatus.MUTED
            heard -> if (mode.value == SoundMode.SILENT) SoundStatus.SILENT else SoundStatus.LISTENING
            !everHeard -> SoundStatus.CONNECTING
            else -> SoundStatus.LOST
        }
        if (s != status.value) Log.add("sound: ${s.title}")
        status.value = s

        // A half-open connection gives no error. Detect it by the silence of the data.
        if (connection.value == Connection.Live && now - max(lastAudio, lastVideo) > 6000 && !App.demo) {
            reconnect("no data for 6 s")
        }
        // The alert. Only a loss that lasts 20 s gives a notification.
        if (s == SoundStatus.LOST) {
            if (lostSince == null) lostSince = now
            if (!alerted && Settings.alertOnLoss.value && now - lostSince!! > 20_000) {
                alerted = true
                Alerts.loss(context)
            }
        } else {
            lostSince = null
            if (alerted && (s == SoundStatus.LISTENING || s == SoundStatus.SILENT)) { alerted = false; Alerts.clearLoss(context) }
        }
        if (App.demo) return
        val am = context.getSystemService(AudioManager::class.java)
        volume.value = am.getStreamVolume(AudioManager.STREAM_MUSIC).toFloat() / max(1, am.getStreamMaxVolume(AudioManager.STREAM_MUSIC))
    }

    /** The words hold: louder after 0.4 s, quieter after 2.5 s. They do not flicker. */
    private fun holdRoomLevel(next: RoomLevel, now: Long) {
        val current = roomLevel.value
        when {
            next > current -> {
                quieterSince = null
                if (louderSince == null) louderSince = now
                if (now - louderSince!! >= 400) { roomLevel.value = next; louderSince = null }
            }
            next < current -> {
                louderSince = null
                if (quieterSince == null) quieterSince = now
                if (now - quieterSince!! >= 2500) { roomLevel.value = next; quieterSince = null }
            }
            else -> { louderSince = null; quieterSince = null }
        }
    }

    /** "Ozývá se": a sound above the level of fussing for 1 s, until 4 s of quiet. */
    private fun detectSound(level: Float, now: Long) {
        if (level >= 0.35f) {
            belowSince = null
            if (!soundNow.value) {
                if (aboveSince == null) aboveSince = now
                if (now - aboveSince!! >= 1000) {
                    soundNow.value = true
                    if (mode.value == SoundMode.SILENT) Alerts.sound(context)
                }
            }
            if (soundNow.value) lastSound.value = now
        } else {
            aboveSince = null
            if (soundNow.value) {
                if (belowSince == null) belowSince = now
                if (now - belowSince!! >= 4000) soundNow.value = false
            }
        }
    }

    /** The volume the phone plays at. Android lets an app set it, unlike iOS. */
    fun raiseVolume() {
        val am = context.getSystemService(AudioManager::class.java)
        val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        am.setStreamVolume(AudioManager.STREAM_MUSIC, (max * 0.6f).toInt().coerceAtLeast(1), AudioManager.FLAG_SHOW_UI)
    }

    // MARK: The photo ("Nahlédnout")

    fun snapshot(): ByteArray? {
        if (App.demo) return null
        val url = if (Settings.source.value == Settings.Source.CAMERA) {
            "http://${Settings.host.value.trim()}:1984/api/frame.jpeg?src=nursery_sd"
        } else {
            val (host, port) = BabyFinder.resolve(context, Settings.babyName.value) ?: return null
            "http://$host:$port/${Settings.babyCode.value}/frame.jpeg"
        }
        return try {
            val c = URL(url).openConnection() as HttpURLConnection
            c.connectTimeout = 5000
            c.readTimeout = 8000
            if (c.responseCode == 200) c.inputStream.use { it.readBytes() } else null
        } catch (e: IOException) {
            Log.add("snapshot failed: ${e.message}")
            null
        }
    }

    // MARK: Demo

    private fun demo() {
        connection.value = Connection.Live
        lastAudio = Long.MAX_VALUE / 2
        lastVideo = if (soundOnly) 0 else Long.MAX_VALUE / 2
        if (App.demoScreen == "muted") setMode(SoundMode.OFF)
        if (App.demoScreen == "volume") volume.value = 0.12f
    }

    private fun demoLevel(now: Long): Float {
        val t = now / 1000.0
        val noise = 0.1f + (Math.random() * 0.05).toFloat()
        return if (t % 12 < 3) max(noise, (kotlin.math.abs(kotlin.math.sin(t * 5.5)) * 0.55 + 0.3).toFloat()) else noise
    }
}
