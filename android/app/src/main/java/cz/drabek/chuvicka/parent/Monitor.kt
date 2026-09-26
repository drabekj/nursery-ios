package cz.drabek.chuvicka.parent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.os.Build
import android.os.PowerManager
import androidx.core.content.ContextCompat
import cz.drabek.chuvicka.App
import cz.drabek.chuvicka.Go2rtc
import cz.drabek.chuvicka.HomeDefaults
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
    LISTENING("Živý zvuk"), SILENT("Ztlumeno"), CONNECTING("Připojování…"), LOST("Zvuk vypadl"), MUTED("Zvuk vypnut")
}

/** Muted is not off: nothing plays, but the app still hears the room and warns about a cry.
 * Only the power button stops the listening. */
enum class SoundMode(val title: String) { LIVE("Živý zvuk"), OFF("Ztlumeno") }

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
    val mode = MutableStateFlow(Settings.soundMode.value)
    val roomLevel = MutableStateFlow(RoomLevel.QUIET)
    val history = MutableStateFlow(List(60) { 0f })
    val pictureLive = MutableStateFlow(false)
    val videoSize = MutableStateFlow(16 to 9)
    val volume = MutableStateFlow(1f)                 // The phone's media volume, 0...1.
    val soundNow = MutableStateFlow(false)
    val lastSound = MutableStateFlow<Long?>(null)
    /** True when the stream goes over Tailscale: the phone is away from home. */
    val viaTailscale = MutableStateFlow(false)
    /** The address of the phone at the baby now, when Bonjour does not find it (away from home). */
    @Volatile private var babyDirect: Pair<String, Int>? = null
    /** The parent turned the monitor off: in the app, in the notification, or by closing the app. */
    val paused = MutableStateFlow(false)
    /** Night mode: the picture is not needed. */
    val night = MutableStateFlow(false)
    /** The app is on the screen. MainActivity sets it. */
    val foreground = MutableStateFlow(false)
    /** The connection now uses the detail (main) stream of the camera. */
    val detailActive = MutableStateFlow(false)

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

    /** The picture is big (the phone turned sideways). Only then the main stream: the main stream
     *  has many times the pixels of the sub stream and keeps the Wi-Fi and the decoder busy. */
    @Volatile private var detail = false
    /** A hot phone and Battery Saver get the sub stream too. */
    @Volatile private var thermalHot = false
    @Volatile private var powerSave = false
    /** The camera URL of the current connection, to see if a change needs a new stream. */
    @Volatile private var currentUrl: String? = null
    private var thermalListener: Any? = null
    private var powerSaveReceiver: BroadcastReceiver? = null

    fun setDetail(on: Boolean) {
        if (detail == on) return
        detail = on
        refreshStream(if (on) "detail: main stream" else "no detail: sub stream")
    }

    private fun cameraInputs() = StreamPolicy.Inputs(
        wantsDetail = detail, soundOnly = soundOnly, thermalHot = thermalHot, powerSave = powerSave,
        detailStream = Settings.cameraUrl(small = false), everydayStream = Settings.cameraUrl(small = true),
    )

    /** A new stream only when the wanted camera URL differs from the current one. */
    private fun refreshStream(why: String) {
        if (Settings.source.value != Settings.Source.CAMERA || soundOnly || client == null) return
        if (StreamPolicy.stream(cameraInputs()) != currentUrl) reconnect(why)
    }

    fun start(context: Context) {
        if (running) return
        this.context = context.applicationContext
        running = true
        mode.value = Settings.soundMode.value
        player = AudioPlayer().also {
            it.gainDb = Settings.loudness.value.decibels
            it.muted = mode.value != SoundMode.LIVE
        }
        watchPower()
        thread = Thread({ loop() }, "monitor").apply { start() }
        Log.add("monitor on")
    }

    fun stop() {
        running = false
        client?.close()
        thread?.interrupt()
        player?.release()
        player = null
        unwatchPower()
        connection.value = Connection.Idle
        detailActive.value = false
        Log.add("monitor off")
    }

    /** The heat and Battery Saver, from the system. Both ask for the sub stream. */
    private fun watchPower() {
        val pm = context.getSystemService(PowerManager::class.java)
        if (Build.VERSION.SDK_INT >= 29) {
            thermalChanged(pm.currentThermalStatus)
            val listener = PowerManager.OnThermalStatusChangedListener { thermalChanged(it) }
            pm.addThermalStatusListener(listener)
            thermalListener = listener
        }
        powerSaveChanged(pm.isPowerSaveMode)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) = powerSaveChanged(pm.isPowerSaveMode)
        }
        ContextCompat.registerReceiver(context, receiver, IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED),
            ContextCompat.RECEIVER_NOT_EXPORTED)
        powerSaveReceiver = receiver
    }

    private fun unwatchPower() {
        if (!::context.isInitialized) return        // The service stopped before it started the monitor.
        val pm = context.getSystemService(PowerManager::class.java)
        if (Build.VERSION.SDK_INT >= 29) {
            (thermalListener as? PowerManager.OnThermalStatusChangedListener)?.let { pm.removeThermalStatusListener(it) }
        }
        thermalListener = null
        powerSaveReceiver?.let { try { context.unregisterReceiver(it) } catch (_: IllegalArgumentException) {} }
        powerSaveReceiver = null
    }

    private fun thermalChanged(status: Int) {
        val hot = status >= PowerManager.THERMAL_STATUS_MODERATE
        if (hot == thermalHot) return
        thermalHot = hot
        Log.add("thermal status $status: ${if (hot) "sub stream until the phone cools" else "normal picture"}")
        refreshStream("thermal state changed")
    }

    private fun powerSaveChanged(on: Boolean) {
        if (on == powerSave) return
        powerSave = on
        Log.add(if (on) "battery saver on: sub stream" else "battery saver off")
        refreshStream("battery saver changed")
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
        if (!App.demo) Settings.set(Settings.soundMode, "soundMode", m)
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
                // The phone at the baby tells its addresses. Keep them for the time away from home.
                if (Settings.source.value == Settings.Source.PHONE && c.serverAddresses.isNotEmpty() &&
                    c.serverAddresses != Settings.babyAddresses.value) {
                    Settings.setBabyAddresses(c.serverAddresses)
                    Log.add("baby phone addresses: ${c.serverAddresses.joinToString()}")
                }
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
                val why = (e.message ?: "Spojení se ukončilo.").let {
                    if (failures >= 2 && Settings.source.value == Settings.Source.CAMERA &&
                        Settings.cameraKind.value == Settings.KIND_GO2RTC && "Tailscale" !in it)
                        "$it Mimo domov zapněte v telefonu Tailscale." else it
                }
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

    /**
     * The way to the stream. At home: the Pi's LAN address, or the phone at the baby by mDNS.
     * Away from home neither works, so: the Pi's Tailscale address, or the addresses that the
     * phone at the baby reported at home. The phone that watches must have Tailscale on.
     */
    private fun open(): RtspClient {
        if (Settings.source.value == Settings.Source.CAMERA) {
            if (Settings.cameraKind.value == Settings.KIND_RTSP) {
                // An IP camera cannot run Tailscale: only at home.
                Settings.activeHost.value = ""
                viaTailscale.value = false
                return openCamera()
            }
            val home = Settings.host.value.trim()
            val remote = Settings.remoteHost.value.trim()
            val host = if (remote.isNotEmpty() && remote != home && !RtspClient.canConnect(home, Go2rtc.RTSP_PORT)) remote else home
            if (Settings.activeHost.value != host) Log.add("server: ${if (host == home) "home" else "Tailscale"} $host")
            Settings.activeHost.value = host
            viaTailscale.value = host != home
            return openCamera()
        }
        currentUrl = null
        detailActive.value = false
        val name = Settings.babyName.value
        val code = Settings.babyCode.value
        if (name.isEmpty() || code.isEmpty()) throw IOException("Není spárovaný telefon u miminka. Spárujte ho v Nastavení.")
        // The addresses that the phone reported last time first: the home Wi-Fi, then Tailscale.
        // They need no mDNS, which a phone with the screen off often stops answering.
        // mDNS only when none answers, for example when the router gave the phone a new address.
        val target = Settings.babyAddresses.value
            .sortedBy { RtspClient.isTailscale(it.substringBeforeLast(":")) }
            .firstNotNullOfOrNull { a ->
                val host = a.substringBeforeLast(":")
                val port = a.substringAfterLast(":").toIntOrNull() ?: return@firstNotNullOfOrNull null
                if (RtspClient.canConnect(host, port)) (host to port).also { viaTailscale.value = RtspClient.isTailscale(host) } else null
            }
            ?: BabyFinder.resolve(context, name)?.also { viaTailscale.value = false }
            ?: throw IOException(awayHint("Telefon u miminka „$name“ není v síti. Běží na něm vysílání?"))
        babyDirect = target
        // The host in the URL is not used: the socket goes to the found address. The code is the path.
        return RtspClient("rtsp://chuvicka/$code" + if (soundOnly) "?audio" else "", target.first, target.second)
    }

    /** The camera stream that StreamPolicy chooses. The sound only always gets the sub stream. */
    private fun openCamera(): RtspClient {
        val inputs = cameraInputs()
        val url = StreamPolicy.stream(inputs)
        currentUrl = url
        detailActive.value = StreamPolicy.detail(inputs)
        return RtspClient.forUrl(url)
    }

    private fun awayHint(message: String): String {
        val tailscale = Settings.babyAddresses.value.any { RtspClient.isTailscale(it.substringBeforeLast(":")) }
        return if (tailscale) "$message Mimo domov zapněte Tailscale na obou telefonech."
        else "$message Mimo domov: nainstalujte Tailscale i na telefon u miminka a jednou se k němu připojte doma."
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
        smoothed = if (raw > smoothed) raw else smoothed * 0.82f + raw * 0.18f
        history.value = history.value.drop(1) + smoothed
        holdRoomLevel(RoomLevel.of(smoothed), now)
        detectSound(smoothed, now)

        pictureLive.value = now - lastVideo < 3000
        val heard = now - lastAudio < 3000
        if (heard) everHeard = true
        val s = when {
            heard -> if (mode.value == SoundMode.OFF) SoundStatus.SILENT else SoundStatus.LISTENING
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
            if (!alerted && now - lostSince!! > 20_000) {
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
                    // Warn when the parent may not hear it: the sound muted, or the phone volume low.
                    // With "every sound" on, warn also then, but not while the app is on the screen and heard.
                    val unheard = mode.value == SoundMode.OFF || volume.value < 0.2f
                    val wanted = unheard || Settings.alertOnSound.value
                    if (wanted && !(foreground.value && !unheard)) Alerts.sound(context)
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
            if (Settings.cameraKind.value == Settings.KIND_RTSP) return null      // An IP camera gives no photo here.
            "http://${Settings.serverHost}:${Go2rtc.API_PORT}/api/frame.jpeg?src=${Settings.encode(Settings.streamMain.value.trim().ifEmpty { HomeDefaults.STREAM_MAIN })}"
        } else {
            val (host, port) = babyDirect ?: BabyFinder.resolve(context, Settings.babyName.value) ?: return null
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
