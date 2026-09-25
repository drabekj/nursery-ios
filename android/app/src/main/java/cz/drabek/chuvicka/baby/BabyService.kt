package cz.drabek.chuvicka.baby

import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.lifecycle.LifecycleService
import cz.drabek.chuvicka.App
import cz.drabek.chuvicka.Log
import cz.drabek.chuvicka.MainActivity
import cz.drabek.chuvicka.R
import cz.drabek.chuvicka.Settings
import cz.drabek.chuvicka.proto.BABY_SERVICE_TYPE
import kotlinx.coroutines.flow.MutableStateFlow
import java.util.Timer
import kotlin.concurrent.fixedRateTimer

/** What the screen of the phone at the baby shows. */
object BabyState {
    val running = MutableStateFlow(false)
    val parents = MutableStateFlow(0)
    val history = MutableStateFlow(List(60) { 0f })
    val error = MutableStateFlow<String?>(null)
    @Volatile var capture: BabyCapture? = null
}

/**
 * The phone at the baby, as a foreground service. Android lets it use the camera and the
 * microphone with the screen off, which iOS does not. A partial wake lock keeps the CPU on,
 * and a Wi-Fi lock keeps the Wi-Fi fast, so the stream does not stall at night.
 */
class BabyService : LifecycleService() {
    private var server: BabyServer? = null
    private var capture: BabyCapture? = null
    private var nsd: NsdManager? = null
    private var registration: NsdManager.RegistrationListener? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var timer: Timer? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        if (intent?.action == ACTION_STOP) { stopSelf(); return START_NOT_STICKY }
        if (server != null) return START_STICKY
        val video = Settings.unitVideo.value
        val type = if (video) ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                   else ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        ServiceCompat.startForeground(this, 2, notification(0), if (Build.VERSION.SDK_INT >= 30) type else 0)
        start(video)
        return START_STICKY
    }

    private fun start(video: Boolean) {
        BabyState.error.value = null
        if (App.demo) { BabyState.running.value = true; BabyState.parents.value = 1; startTimer(); return }
        lateinit var capture: BabyCapture
        val server = BabyServer(
            code = Settings.unitCode.value,
            hasVideo = video,
            onClients = { all, withVideo ->
                BabyState.parents.value = all
                capture.setEncoding(withVideo > 0)
                updateNotification(all)
            },
            onNeedKeyframe = { capture.requestKeyframe() },
            onFrameRequest = { if (video) capture.frame() else null },
        )
        capture = BabyCapture(this, server)
        this.server = server
        this.capture = capture
        BabyState.capture = capture
        val port = try { server.start() } catch (e: Exception) {
            BabyState.error.value = "Vysílání se nepodařilo spustit (${e.message})."
            stopSelf(); return
        }
        capture.startAudio()
        if (video) capture.startVideo(this, Settings.unitFront.value)
        register(port)

        val pm = getSystemService(PowerManager::class.java)
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "chuvicka:baby").apply { acquire() }
        val wm = applicationContext.getSystemService(WifiManager::class.java)
        @Suppress("DEPRECATION")
        val mode = if (Build.VERSION.SDK_INT >= 29) WifiManager.WIFI_MODE_FULL_LOW_LATENCY else WifiManager.WIFI_MODE_FULL_HIGH_PERF
        wifiLock = wm.createWifiLock(mode, "chuvicka:baby").apply { acquire() }
        BabyState.running.value = true
        startTimer()
        Log.add("baby phone on, ${if (video) "picture and sound" else "sound only"}")
    }

    /** mDNS: the parents find "Pokojíček" on the Wi-Fi. The iOS app browses the same type. */
    private fun register(port: Int) {
        val info = NsdServiceInfo().apply {
            serviceName = Settings.unitName.value.trim().ifEmpty { "Pokojíček" }.take(40)
            serviceType = BABY_SERVICE_TYPE
            setPort(port)
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(s: NsdServiceInfo) { Log.add("baby phone announced as ${s.serviceName}") }
            override fun onRegistrationFailed(s: NsdServiceInfo, code: Int) {
                BabyState.error.value = "Telefon se nepodařilo ohlásit v síti (chyba $code)."
            }
            override fun onServiceUnregistered(s: NsdServiceInfo) {}
            override fun onUnregistrationFailed(s: NsdServiceInfo, code: Int) {}
        }
        nsd = getSystemService(NsdManager::class.java).also { it.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener) }
        registration = listener
    }

    private var smoothed = 0f

    private fun startTimer() {
        timer = fixedRateTimer("baby-level", period = 100) {
            val raw = if (App.demo) {
                val t = System.currentTimeMillis() / 1000
                (0.08f + Math.random().toFloat() * 0.08f) + if (t % 12 < 2) 0.6f else 0f
            } else capture?.let { c -> c.peak.also { c.peak = 0f } } ?: 0f
            smoothed = if (raw > smoothed) raw else smoothed * 0.82f + raw * 0.18f
            BabyState.history.value = BabyState.history.value.drop(1) + smoothed
        }
    }

    private fun notification(parents: Int): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, BabyService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, App.CHANNEL_RUNNING)
            .setSmallIcon(R.drawable.ic_stat)
            .setContentTitle("Chůvička vysílá")
            .setContentText(when (parents) { 0 -> "Čeká na telefon rodiče"; 1 -> "Vysílá do 1 telefonu"; else -> "Vysílá do $parents telefonů" })
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(0, "Ukončit", stop)
            .build()
    }

    private fun updateNotification(parents: Int) {
        getSystemService(android.app.NotificationManager::class.java).notify(2, notification(parents))
    }

    override fun onDestroy() {
        timer?.cancel()
        registration?.let { try { nsd?.unregisterService(it) } catch (_: Exception) {} }
        capture?.stop()
        server?.stop()
        BabyState.capture = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wifiLock?.let { if (it.isHeld) it.release() }
        BabyState.running.value = false
        BabyState.parents.value = 0
        BabyState.history.value = List(60) { 0f }
        Log.add("baby phone off")
        super.onDestroy()
    }

    companion object {
        private const val ACTION_STOP = "stop"
        fun start(context: Context) = context.startForegroundService(Intent(context, BabyService::class.java))
        fun stop(context: Context) = context.stopService(Intent(context, BabyService::class.java))
    }
}
