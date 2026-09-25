package cz.drabek.chuvicka

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.SharedPreferences
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

    private lateinit var p: SharedPreferences

    val role = MutableStateFlow(Role.PARENT)
    val source = MutableStateFlow(Source.CAMERA)
    val host = MutableStateFlow("192.168.0.136")
    /** The Pi's Tailscale address, for the time away from home. */
    val remoteHost = MutableStateFlow("100.104.188.72")
    /** The Pi now: at home its LAN address, away its Tailscale address. The monitor sets it. */
    val activeHost = MutableStateFlow("")
    /** The addresses that the phone at the baby reported ("100.x.y.z:8555" first). */
    val babyAddresses = MutableStateFlow<List<String>>(emptyList())
    val babyName = MutableStateFlow("")
    val babyCode = MutableStateFlow("")
    val soundView = MutableStateFlow(false)
    val loudness = MutableStateFlow(Loudness.NORMAL)
    val appearance = MutableStateFlow(Appearance.LIGHT)
    val alertOnLoss = MutableStateFlow(true)
    val unitName = MutableStateFlow("Pokojíček")
    val unitCode = MutableStateFlow("")
    val unitVideo = MutableStateFlow(true)
    val unitFront = MutableStateFlow(false)

    fun init(context: Context) {
        p = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
        role.value = enumValueOrNull<Role>(p.getString("role", null)) ?: Role.PARENT
        source.value = enumValueOrNull<Source>(p.getString("source", null)) ?: Source.CAMERA
        host.value = p.getString("host", null) ?: "192.168.0.136"
        remoteHost.value = p.getString("remoteHost", null) ?: "100.104.188.72"
        babyAddresses.value = p.getString("babyAddresses", "")!!.split(",").filter { it.isNotBlank() }
        babyName.value = p.getString("babyName", "") ?: ""
        babyCode.value = p.getString("babyCode", "") ?: ""
        soundView.value = p.getBoolean("soundView", false)
        loudness.value = enumValueOrNull<Loudness>(p.getString("loudness", null)) ?: Loudness.NORMAL
        appearance.value = enumValueOrNull<Appearance>(p.getString("appearance", null)) ?: Appearance.LIGHT
        alertOnLoss.value = p.getBoolean("alertOnLoss", true)
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

    /** The Pi now. */
    val serverHost get() = activeHost.value.ifEmpty { host.value.trim() }

    fun newCode() = "%06d".format(Random.nextInt(0, 1_000_000))

    /** The stream URL. The Tapo camera is read through go2rtc on the Pi, never directly. */
    fun cameraUrl(soundOnly: Boolean): String {
        // Sound only: the 360p stream with its picture, which the app does not draw. Not "?audio":
        // go2rtc then asks the Tapo camera for the sound track only, and the camera sends nothing.
        val name = if (soundOnly) "nursery_sd" else "nursery"
        return "rtsp://$serverHost:8554/$name"
    }

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
