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
import cz.drabek.chuvicka.Net
import cz.drabek.chuvicka.Settings
import cz.drabek.chuvicka.proto.AccessUnit
import cz.drabek.chuvicka.proto.G711
import cz.drabek.chuvicka.proto.H264Depacketizer
import cz.drabek.chuvicka.proto.RtpPacket
import cz.drabek.chuvicka.proto.RtspClient
import cz.drabek.chuvicka.proto.levelFromRms
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.runBlocking
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
    /** The level of a sound event ("Ozývá se"). Fixed; iOS derives it from the noise floor. */
    const val SOUND_THRESHOLD = 0.35f

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
    /** The room in one word: Připojuji…, Klid, Ozývá se, Pláče, Nehlídá. Updated at 2 Hz, emitted only on a change. */
    val roomState: StateFlow<RoomState> get() = _roomState
    private val _roomState = MutableStateFlow(RoomState.CONNECTING)
    /** When [roomState] last changed (System.currentTimeMillis). */
    val roomStateSince: StateFlow<Long> get() = _roomStateSince
    private val _roomStateSince = MutableStateFlow(System.currentTimeMillis())
    /** When the last sound event ended ("ticho už 42 min"). Null: no event since the start. */
    val lastEventEnd: StateFlow<Long?> get() = _lastEventEnd
    private val _lastEventEnd = MutableStateFlow<Long?>(null)
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
    /** A short message for a toast ("Kamera nalezena na nové adrese"). The screen shows it and sets it back to null. */
    val notice = MutableStateFlow<String?>(null)
    /** The direct camera can turn (ONVIF PTZ): the screen shows "Natočit". */
    val ptzReady = MutableStateFlow(false)
    @Volatile private var onvif: OnvifClient? = null
    /** The camera control was checked for this connection. open() and reconnect() reset it. */
    @Volatile private var controlChecked = false
    /** The camera settings of the last check, to skip a new check after a mere reconnect. */
    @Volatile private var controlKey: String? = null
    /** The last search for a camera that moved to a new address (DHCP): at most once a minute. */
    private var lastRelocation = 0L

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
    /** The running sound event: its start and its peak level. */
    private var eventStart: Long? = null
    private var eventPeak = 0f
    private var machine = newMachine()
    private var ticks = 0
    /** The cry classifier, from the start to the stop of the monitor. Never in the demo. */
    @Volatile private var cry: CryDetector? = null

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
        machine = newMachine()
        cry = if (App.demo) null else CryDetector(this.context)
        _roomState.value = RoomState.CONNECTING
        _roomStateSince.value = System.currentTimeMillis()
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
        cry?.close()
        cry = null
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
        controlChecked = false
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
                checkCameraControl()
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
                if (e is RtspClient.CameraFull) {
                    // Other phones hold the camera's few sessions: a fixed, longer pause, and words for people.
                    connection.value = Connection.Retrying(e.message ?: "", failures)
                    Log.add("camera full, retry in 15 s")
                    try { Thread.sleep(15_000) } catch (_: InterruptedException) {}
                    continue
                }
                if (relocate(e, failures)) continue
                val why = (e.message ?: "Spojení se ukončilo.").let {
                    val camera = failures >= 2 && Settings.source.value == Settings.Source.CAMERA && "Tailscale" !in it
                    when {
                        camera && Settings.cameraKind.value == Settings.KIND_GO2RTC -> "$it Mimo domov zapněte v telefonu Tailscale."
                        camera && Settings.cameraKind.value == Settings.KIND_RTSP ->
                            "$it Mimo domov to funguje jen přes domácí Tailscale (Nastavení → Pro pokročilé → Mimo domov)."
                        else -> it
                    }
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
        controlChecked = false
        if (Settings.source.value == Settings.Source.CAMERA) {
            if (Settings.cameraKind.value == Settings.KIND_RTSP) {
                // The camera's LAN address everywhere: away from home the home's Tailscale route reaches it.
                // viaTailscale is only for the "Cesta" row: Tailscale on and not in the camera's network.
                Settings.activeHost.value = ""
                viaTailscale.value = Net.hasTailscale() && !sameNetwork(cameraHost(), Net.ipv4())
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
        return RtspClient.forUrl(url, directCamera = Settings.cameraKind.value == Settings.KIND_RTSP)
    }

    /** The host of the direct camera's saved URL, or "" when the URL is not valid. */
    private fun cameraHost(): String = try {
        RtspClient.parse(Settings.rtspUrl.value.trim()).host
    } catch (_: Exception) {
        ""
    }

    /** True when one of this phone's private addresses has the camera's first three parts ("192.168.0"). */
    private fun sameNetwork(host: String, own: List<String>): Boolean {
        val prefix = host.split(".").take(3).joinToString(".")
        if (host.isEmpty()) return true
        return own.filter { isPrivateIpv4(it) }.any { it.split(".").take(3).joinToString(".") == prefix }
    }

    private fun isPrivateIpv4(ip: String): Boolean {
        val p = ip.split(".").mapNotNull { it.toIntOrNull() }
        return p.size == 4 && (p[0] == 10 || (p[0] == 172 && p[1] in 16..31) || (p[0] == 192 && p[1] == 168))
    }

    /**
     * The direct camera does not answer at its saved address: maybe the router gave it a new one.
     * After 2 failures, at most once a minute, look for it on the home Wi-Fi and adopt the new address.
     * Not for a wrong password (the camera answered) and not for "Jiná kamera" (no known path).
     */
    private fun relocate(e: Exception, failures: Int): Boolean {
        if (failures < 2 || Settings.source.value != Settings.Source.CAMERA || Settings.cameraKind.value != Settings.KIND_RTSP) return false
        if (Settings.rtspBrand.value == Settings.CameraBrand.OTHER || isLoginError(e)) return false
        val now = System.currentTimeMillis()
        if (now - lastRelocation < 60_000) return false
        lastRelocation = now
        val found: String? = try {
            runBlocking { CameraFinder.relocate() }
        } catch (x: Exception) {
            Log.add("camera search failed: ${x.javaClass.simpleName}")
            null
        }
        val host = found ?: return false
        Settings.set(Settings.rtspUrl, "rtspUrl", replaceHost(Settings.rtspUrl.value, host))
        if (Settings.rtspUrlSmall.value.isNotBlank()) {
            Settings.set(Settings.rtspUrlSmall, "rtspUrlSmall", replaceHost(Settings.rtspUrlSmall.value, host))
        }
        Log.add("camera moved to $host")
        notice.value = "Kamera nalezena na nové adrese"
        return true
    }

    /** The 401 texts of RtspClient: the camera is there, only the login is wrong. */
    private fun isLoginError(e: Exception): Boolean {
        val m = e.message ?: return false
        return e is RtspClient.Failure && (m.startsWith("Kamera nepřijala") || m.startsWith("Kamera chce"))
    }

    // MARK: The camera control (ONVIF PTZ)

    /** After Live, once per connection: check in a small thread if the camera can turn. The packets do not wait. */
    private fun checkCameraControl() {
        if (controlChecked) return
        controlChecked = true
        if (Settings.source.value != Settings.Source.CAMERA || Settings.cameraKind.value != Settings.KIND_RTSP) {
            onvif = null
            ptzReady.value = false
            return
        }
        // A mere reconnect (a new view) with the same camera settings: the last answer holds.
        if (controlKey == cameraControlKey() && ptzReady.value) return
        Thread({
            try { loadCameraControl() } catch (e: Exception) { Log.add("camera control: ${e.javaClass.simpleName}") }
        }, "camera-control").apply { isDaemon = true; start() }
    }

    private fun cameraControlKey(): String =
        "${Settings.rtspUrl.value.trim()}|${Settings.rtspUser.value}|${Settings.rtspBrand.value}|${Settings.rtspPassword.hashCode()}"

    /**
     * It asks the direct camera for a profile that can turn (ONVIF GetProfiles on the brand's port).
     * Blocking: the monitor calls it in a thread, the screen may call it on Dispatchers.IO (after a settings change).
     */
    fun loadCameraControl() {
        if (App.demo || Settings.source.value != Settings.Source.CAMERA || Settings.cameraKind.value != Settings.KIND_RTSP) {
            onvif = null
            ptzReady.value = false
            return
        }
        val key = cameraControlKey()
        val host = cameraHost()
        if (host.isEmpty()) {
            onvif = null
            ptzReady.value = false
            return
        }
        val client = OnvifClient(host, Settings.rtspBrand.value.onvifPort, Settings.rtspUser.value, Settings.rtspPassword)
        val ready = client.loadPtzProfile() != null
        onvif = if (ready) client else null
        ptzReady.value = ready
        controlKey = key
        Log.add("camera control ready: ONVIF move $ready")
    }

    /** One step of the camera (about 0.6 s of turning). Blocking: call it on Dispatchers.IO. */
    fun move(direction: PtzDirection): Boolean {
        val (x, y) = when (direction) {
            PtzDirection.LEFT -> -0.5f to 0f
            PtzDirection.RIGHT -> 0.5f to 0f
            PtzDirection.UP -> 0f to 0.5f
            PtzDirection.DOWN -> 0f to -0.5f
        }
        return onvif?.step(x, y) ?: false
    }

    private fun awayHint(message: String): String {
        val tailscale = Settings.babyAddresses.value.any { RtspClient.isTailscale(it.substringBeforeLast(":")) }
        return if (tailscale) "$message Mimo domov zapněte Tailscale na obou telefonech."
        else "$message Mimo domov: nainstalujte Tailscale i na telefon u miminka a jednou se k němu připojte doma."
    }

    private fun measure(p: RtpPacket, uLaw: Boolean) {
        val table = if (uLaw) G711.uLaw else G711.aLaw
        // The cry classifier gets a copy of the samples, only while a sound event runs.
        val detector = cry
        val samples = if (detector != null && detector.wanted && p.length > 0) FloatArray(p.length) else null
        var sum = 0.0
        for (i in 0 until p.length) {
            val s = table[p.data[p.offset + i].toInt() and 0xFF] / 32768.0
            sum += s * s
            if (samples != null) samples[i] = s.toFloat()
        }
        if (p.length > 0) peak = max(peak, levelFromRms(sqrt(sum / p.length)))
        if (samples != null) detector?.feed(samples)
    }

    // MARK: The tick, 10 times a second, from the service

    fun tick(now: Long = System.currentTimeMillis()) {
        val raw = if (App.demo) demoLevel(now) else peak.also { peak = 0f }
        smoothed = if (raw > smoothed) raw else smoothed * 0.82f + raw * 0.18f
        history.value = history.value.drop(1) + smoothed
        holdRoomLevel(RoomLevel.of(smoothed), now)
        detectSound(smoothed, now)
        cry?.setActive(soundNow.value)

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
            if (!alerted && now - lostSince!! > 20_000 && !App.demo) {
                alerted = true
                Alerts.loss(context)
            }
        } else {
            lostSince = null
            if (alerted && (s == SoundStatus.LISTENING || s == SoundStatus.SILENT)) { alerted = false; Alerts.clearLoss(context) }
        }
        // The room state at 2 Hz: every 5th tick.
        if (++ticks % 5 == 0) { if (App.demo) demoRoomState(now) else updateRoomState(now) }
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

    /** The room state from the signals. The machine keeps the rules, see RoomState.kt. */
    private fun updateRoomState(now: Long) {
        val detector = cry
        if (detector != null) while (true) machine.classified(detector.verdicts.poll() ?: break)
        val s = status.value
        val input = RoomStateMachine.Input(
            heard = s == SoundStatus.LISTENING || s == SoundStatus.SILENT,
            everHeard = everHeard,
            eventRunning = soundNow.value,
            eventSeconds = eventStart?.let { (now - it) / 1000.0 } ?: 0.0,
            eventPeak = eventPeak,
            level = smoothed,
            loudLevel = max(SOUND_THRESHOLD + 0.15f, 0.45f),
            classifierAvailable = detector?.available ?: false,
        )
        setRoomState(machine.update(input, now), machine.since ?: now)
    }

    /** The machine with the verdict rule of CryDetector: every cry verdict (0.35 and more) counts. */
    private fun newMachine() = RoomStateMachine(cryConfidence = Yamnet.BABY_CRY_MIN)

    /** Emit only on a change. */
    private fun setRoomState(state: RoomState, since: Long) {
        val before = _roomState.value
        if (state == before) return
        _roomStateSince.value = since
        _roomState.value = state
        Log.add("room: ${state.title}")
    }

    /** "Ozývá se": a sound above the level of fussing for 1 s, until 4 s of quiet. */
    private fun detectSound(level: Float, now: Long) {
        if (level >= SOUND_THRESHOLD) {
            belowSince = null
            if (!soundNow.value) {
                if (aboveSince == null) aboveSince = now
                if (now - aboveSince!! >= 1000) {
                    soundNow.value = true
                    eventStart = aboveSince
                    eventPeak = level
                    // Warn when the parent may not hear it: the sound muted, or the phone volume low.
                    // With "every sound" on, warn also then, but not while the app is on the screen and heard.
                    val unheard = mode.value == SoundMode.OFF || volume.value < 0.2f
                    val wanted = unheard || Settings.alertOnSound.value
                    if (wanted && !(foreground.value && !unheard)) Alerts.sound(context)
                }
            }
            if (soundNow.value) {
                lastSound.value = now
                eventPeak = max(eventPeak, level)
            }
        } else {
            aboveSince = null
            if (soundNow.value) {
                if (belowSince == null) belowSince = now
                if (now - belowSince!! >= 4000) {
                    soundNow.value = false
                    _lastEventEnd.value = now
                    eventStart = null
                    eventPeak = 0f
                }
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
            if (Settings.cameraKind.value == Settings.KIND_RTSP) {
                // A short session of its own on the OTHER path than the live stream: a camera allows only
                // about 3 sessions per path, and this phone's live stream holds one of the live path.
                return FrameGrabber.grab(Settings.cameraUrl(small = detailActive.value))
            }
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
        val now = System.currentTimeMillis()
        val state = demoState(App.demoScreen)
        connection.value = Connection.Live
        lastAudio = Long.MAX_VALUE / 2
        lastVideo = if (soundOnly) 0 else Long.MAX_VALUE / 2
        if (App.demoScreen == "muted" || App.demoScreen == "sound-muted") setMode(SoundMode.OFF)
        if (App.demoScreen == "volume") volume.value = 0.12f
        // Nehlídá: heard once, nothing for 2 min. Připojuji…: never heard.
        if (state == RoomState.LOST) {
            everHeard = true
            lastAudio = now - 125_000
            lastVideo = 0
            connection.value = Connection.Retrying("Telefon u miminka neodpovídá.", 3)
        }
        if (state == RoomState.CONNECTING) {
            lastAudio = 0
            lastVideo = 0
            connection.value = Connection.Connecting
        }
        // The times for the sublines: "ticho už 42 min", "už 38 s", "před 2 min".
        _lastEventEnd.value = now - 42 * 60_000
        if (state != null) {
            _roomStateSince.value = when (state) {
                RoomState.CALM -> now - 42 * 60_000
                RoomState.CRY -> now - 38_000
                RoomState.SOUND -> now - 6_000
                else -> now - 105_000
            }
            _roomState.value = state
        }
    }

    /** The demo screens show a fixed room state; null: the state follows the demo level. */
    private fun demoState(screen: String): RoomState? = when (screen) {
        "sound", "sound-muted" -> RoomState.SOUND
        "sound-cry", "main-cry", "night-cry" -> RoomState.CRY
        "sound-lost" -> RoomState.LOST
        "sound-connecting" -> RoomState.CONNECTING
        "parent-dark", "sound-dark" -> null
        else -> RoomState.CALM          // klid, main, parent, and the other screens.
    }

    /** The demo sets the state from the screen name. No classifier in the demo. */
    private fun demoRoomState(now: Long) {
        val state = demoState(App.demoScreen) ?: if (smoothed > SOUND_THRESHOLD) RoomState.SOUND else RoomState.CALM
        setRoomState(state, now)
    }

    private fun demoLevel(now: Long): Float {
        val t = now / 1000.0
        val noise = 0.1f + (Math.random() * 0.05).toFloat()
        return when (demoState(App.demoScreen)) {
            RoomState.CRY -> (kotlin.math.abs(kotlin.math.sin(t * 5.5)) * 0.25 + 0.7).toFloat()
            RoomState.SOUND -> (kotlin.math.abs(kotlin.math.sin(t * 3.1)) * 0.25 + 0.42).toFloat()
            RoomState.LOST, RoomState.CONNECTING -> 0f
            RoomState.CALM -> noise
            null -> if (t % 12 < 3) max(noise, (kotlin.math.abs(kotlin.math.sin(t * 5.5)) * 0.55 + 0.3).toFloat()) else noise
        }
    }
}

/**
 * The URL with a new host: the scheme, the login, the port and the path stay.
 * "rtsp://u:p@192.168.0.197:554/stream1" with "192.168.0.50" is "rtsp://u:p@192.168.0.50:554/stream1".
 */
fun replaceHost(url: String, host: String): String {
    val m = Regex("^(rtsp://(?:[^@/]+@)?)[^:/]+", RegexOption.IGNORE_CASE).find(url) ?: return url
    return url.replaceRange(m.range, m.groupValues[1] + host)
}
