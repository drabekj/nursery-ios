package cz.drabek.chuvicka

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.SharedPreferences
import cz.drabek.chuvicka.parent.SoundMode
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.random.Random

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        Settings.init(this)
        Log.init(this)
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL_RUNNING, "Hlídání běží", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Stav hlídání. Android ho vyžaduje, když aplikace běží se zhasnutým displejem."
            setShowBadge(false)
        })
        nm.createNotificationChannel(NotificationChannel(CHANNEL_ALERTS, "Výpadek a pláč", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Když se přeruší spojení s pokojíčkem nebo když se miminko ozve."
        })
    }

    companion object {
        const val CHANNEL_RUNNING = "running"
        const val CHANNEL_ALERTS = "alerts"
        /** The demo mode shows a still picture and a fake sound, for the screenshots. */
        @Volatile var demo = false
        @Volatile var demoScreen = ""
    }
}

/** The settings. The same choices as in the iOS app. */
object Settings {
    enum class Role { PARENT, BABY }
    enum class Source { CAMERA, PHONE }
    enum class Loudness(val title: String, val decibels: Float) {
        NORMAL("Normální", 0f), LOUD("Zesílená", 12f), MAX("Maximální", 20f)
    }
    enum class Appearance(val title: String) { LIGHT("Světlý"), DARK("Tmavý"), AUTO("Automaticky") }
    /** The RTSP paths of the common IP cameras: the main stream and the sub stream. */
    enum class CameraBrand(val title: String, val main: String, val small: String) {
        TAPO("Tapo", "stream1", "stream2"),
        HIKVISION("Hikvision", "Streaming/Channels/101", "Streaming/Channels/102"),
        DAHUA("Dahua / Imou", "cam/realmonitor?channel=1&subtype=0", "cam/realmonitor?channel=1&subtype=1"),
        REOLINK("Reolink", "h264Preview_01_main", "h264Preview_01_sub"),
        OTHER("Jiná kamera", "", ""),
    }

    const val KIND_GO2RTC = "go2rtc"
    const val KIND_RTSP = "rtsp"

    private lateinit var p: SharedPreferences
    /**
     * The camera password. A plain private file, apart from the other settings: only this app
     * can read it. EncryptedSharedPreferences would need one more library.
     */
    private lateinit var secret: SharedPreferences

    val role = MutableStateFlow(Role.PARENT)
    val source = MutableStateFlow(Source.CAMERA)
    val host = MutableStateFlow(HomeDefaults.SERVER_HOST)
    /** The Pi's Tailscale address, for the time away from home. */
    val remoteHost = MutableStateFlow(HomeDefaults.REMOTE_HOST)
    /** The Pi now: at home its LAN address, away its Tailscale address. The monitor sets it. */
    val activeHost = MutableStateFlow("")
    /** The addresses that the phone at the baby reported ("100.x.y.z:8555" first). */
    val babyAddresses = MutableStateFlow<List<String>>(emptyList())
    val babyName = MutableStateFlow("")
    val babyCode = MutableStateFlow("")
    val soundView = MutableStateFlow(false)
    val loudness = MutableStateFlow(Loudness.NORMAL)
    val appearance = MutableStateFlow(Appearance.AUTO)
    /** Warn about every sound, also when the parent hears it. A muted or quiet phone warns always. */
    val alertOnSound = MutableStateFlow(false)
    /** Live sound or muted. It stays as the parent left it. */
    val soundMode = MutableStateFlow(SoundMode.LIVE)
    val unitName = MutableStateFlow("Pokojíček")
    val unitCode = MutableStateFlow("")
    val unitVideo = MutableStateFlow(true)
    val unitFront = MutableStateFlow(false)
    /** False until the first-run wizard is done. */
    val onboarded = MutableStateFlow(true)
    /** The camera source: "go2rtc" (a server) or "rtsp" (an IP camera read directly). */
    val cameraKind = MutableStateFlow(KIND_GO2RTC)
    /** The go2rtc stream names: the camera's main (high) stream and its sub (low) stream. */
    val streamMain = MutableStateFlow(HomeDefaults.STREAM_MAIN)
    val streamSmall = MutableStateFlow(HomeDefaults.STREAM_SMALL)
    /** The IP camera's streams, full RTSP URLs without the user and the password. */
    val rtspUrl = MutableStateFlow("")
    val rtspUrlSmall = MutableStateFlow("")
    val rtspUser = MutableStateFlow("")
    val rtspBrand = MutableStateFlow(CameraBrand.TAPO)

    fun init(context: Context) {
        p = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
        secret = context.getSharedPreferences("secret", Context.MODE_PRIVATE)
        // An install from before the wizard has settings already: it skips the wizard.
        if (!p.contains("onboarded")) p.edit().putBoolean("onboarded", p.all.keys.any { it != "unitCode" }).apply()
        onboarded.value = p.getBoolean("onboarded", true)
        cameraKind.value = p.getString("cameraKind", null) ?: KIND_GO2RTC
        streamMain.value = p.getString("streamMain", null) ?: HomeDefaults.STREAM_MAIN
        streamSmall.value = p.getString("streamSmall", null) ?: HomeDefaults.STREAM_SMALL
        rtspUrl.value = p.getString("rtspUrl", "") ?: ""
        rtspUrlSmall.value = p.getString("rtspUrlSmall", "") ?: ""
        rtspUser.value = p.getString("rtspUser", "") ?: ""
        rtspBrand.value = enumValueOrNull<CameraBrand>(p.getString("rtspBrand", null)) ?: CameraBrand.TAPO
        role.value = enumValueOrNull<Role>(p.getString("role", null)) ?: Role.PARENT
        source.value = enumValueOrNull<Source>(p.getString("source", null)) ?: Source.CAMERA
        host.value = p.getString("host", null) ?: HomeDefaults.SERVER_HOST
        remoteHost.value = p.getString("remoteHost", null) ?: HomeDefaults.REMOTE_HOST
        babyAddresses.value = p.getString("babyAddresses", "")!!.split(",").filter { it.isNotBlank() }
        babyName.value = p.getString("babyName", "") ?: ""
        babyCode.value = p.getString("babyCode", "") ?: ""
        soundView.value = p.getBoolean("soundView", false)
        loudness.value = enumValueOrNull<Loudness>(p.getString("loudness", null)) ?: Loudness.NORMAL
        appearance.value = enumValueOrNull<Appearance>(p.getString("appearance", null)) ?: Appearance.AUTO
        alertOnSound.value = p.getBoolean("alertOnSound", false)
        soundMode.value = enumValueOrNull<SoundMode>(p.getString("soundMode", null)) ?: SoundMode.LIVE
        unitName.value = p.getString("unitName", null) ?: "Pokojíček"
        unitCode.value = p.getString("unitCode", null) ?: newCode().also { p.edit().putString("unitCode", it).apply() }
        unitVideo.value = p.getBoolean("unitVideo", true)
        unitFront.value = p.getBoolean("unitFront", false)
    }

    fun <T> set(flow: MutableStateFlow<T>, key: String, value: T) {
        flow.value = value
        p.edit().apply {
            when (value) {
                is String -> putString(key, value)
                is Boolean -> putBoolean(key, value)
                is Enum<*> -> putString(key, value.name)
            }
        }.apply()
    }

    fun setBabyAddresses(list: List<String>) {
        babyAddresses.value = list
        p.edit().putString("babyAddresses", list.joinToString(",")).apply()
    }

    var rtspPassword: String
        get() = secret.getString("rtspPassword", "") ?: ""
        set(value) { secret.edit().putString("rtspPassword", value).apply() }

    /** The Pi now. */
    val serverHost get() = activeHost.value.ifEmpty { host.value.trim() }

    /** The name that the phone at the baby announces with mDNS. */
    val unitServiceName get() = unitName.value.trim().ifEmpty { "Pokojíček" }.take(40)

    fun newCode() = "%06d".format(Random.nextInt(0, 1_000_000))

    /**
     * The stream URL: go2rtc on the Pi, or the IP camera directly (with its user and password).
     * Small: the everyday (sub) stream, else the detail (main) stream. StreamPolicy chooses.
     */
    fun cameraUrl(small: Boolean): String {
        if (cameraKind.value == KIND_RTSP) {
            // The sub stream, if the camera has one. Never "?audio", also for the sound only.
            val url = if (small && rtspUrlSmall.value.isNotBlank()) rtspUrlSmall.value else rtspUrl.value
            return withCredentials(url.trim(), rtspUser.value, rtspPassword)
        }
        return go2rtcUrl(serverHost, small)
    }

    fun go2rtcUrl(server: String, small: Boolean): String {
        // The sound only uses the sub stream with its picture, which the app does not draw. Not "?audio":
        // some cameras (e.g. Tapo through go2rtc) send no packets on an audio-only request.
        val name = if (small) streamSmall.value.trim().ifEmpty { HomeDefaults.STREAM_SMALL } else streamMain.value.trim().ifEmpty { HomeDefaults.STREAM_MAIN }
        return "rtsp://$server:${Go2rtc.RTSP_PORT}/$name"
    }

    /** "rtsp://host/path" to "rtsp://user:pass@host/path", both percent-encoded. */
    fun withCredentials(url: String, user: String, password: String): String {
        val rest = if (url.startsWith("rtsp://", ignoreCase = true)) url.substring(7) else url
        if (user.isEmpty() || rest.substringBefore('/').contains('@')) return "rtsp://$rest"
        return "rtsp://${encode(user)}:${encode(password)}@$rest"
    }

    fun encode(s: String): String = java.net.URLEncoder.encode(s, "UTF-8").replace("+", "%20")

    private inline fun <reified T : Enum<T>> enumValueOrNull(name: String?): T? =
        enumValues<T>().firstOrNull { it.name == name }
}

/** The events, for the diagnosis. It survives a restart, like the log of the iOS app. */
object Log {
    private lateinit var file: File
    private val format = SimpleDateFormat("dd.MM. HH:mm:ss", Locale.US)
    private val _lines = MutableStateFlow<List<String>>(emptyList())
    val lines: StateFlow<List<String>> = _lines

    fun init(context: Context) {
        file = File(context.filesDir, "events.log")
        _lines.value = if (file.exists()) file.readLines().takeLast(400) else emptyList()
        file.writeText(_lines.value.joinToString("\n", postfix = if (_lines.value.isEmpty()) "" else "\n"))
    }

    @Synchronized
    fun add(text: String) {
        android.util.Log.i("Chuvicka", text)
        if (!::file.isInitialized) return
        val line = "${format.format(Date())}  $text"
        _lines.value = (_lines.value + line).takeLast(400)
        try { file.appendText(line + "\n") } catch (_: Exception) {}
    }
}
