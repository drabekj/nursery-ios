package cz.drabek.chuvicka.parent

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import cz.drabek.chuvicka.App
import cz.drabek.chuvicka.MainActivity
import cz.drabek.chuvicka.R
import java.util.Timer
import kotlin.concurrent.fixedRateTimer

/**
 * The parent's monitor as a foreground service: the sound goes on with the screen off or in
 * another app. Its notification shows the live state, which Android lets an app update at any
 * time (the iOS Live Activity cannot do this in the background).
 */
class ParentService : Service() {
    private var timer: Timer? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var shown: SoundStatus? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            Monitor.paused.value = true
            stopSelf()
            return START_NOT_STICKY
        }
        ServiceCompat.startForeground(this, 1, notification(Monitor.status.value),
            if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK else 0)
        if (timer == null) {
            Monitor.start(this)
            val pm = getSystemService(PowerManager::class.java)
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "chuvicka:parent").apply { acquire() }
            val wm = applicationContext.getSystemService(WifiManager::class.java)
            @Suppress("DEPRECATION")
            val mode = if (Build.VERSION.SDK_INT >= 29) WifiManager.WIFI_MODE_FULL_LOW_LATENCY else WifiManager.WIFI_MODE_FULL_HIGH_PERF
            wifiLock = wm.createWifiLock(mode, "chuvicka:parent").apply { acquire() }
            timer = fixedRateTimer("monitor-tick", period = 100) {
                Monitor.tick()
                val s = Monitor.status.value
                if (s != shown) {
                    shown = s
                    getSystemService(NotificationManager::class.java).notify(1, notification(s))
                }
            }
        }
        return START_STICKY
    }

    private fun notification(s: SoundStatus): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, ParentService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, App.CHANNEL_RUNNING)
            .setSmallIcon(R.drawable.ic_stat)
            .setContentTitle("Chůvička hlídá")
            .setContentText(s.title)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .addAction(0, "Ukončit hlídání", stop)
            .build()
    }

    /** Swiped away from the recent apps: the user closed Chůvička, so it stops watching. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        cz.drabek.chuvicka.Log.add("app closed by the user")
        stopSelf()                       // The next start of the app watches again, as on the iPhone.
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        timer?.cancel()
        timer = null
        Monitor.stop()
        wakeLock?.let { if (it.isHeld) it.release() }
        wifiLock?.let { if (it.isHeld) it.release() }
        super.onDestroy()
    }

    companion object {
        private const val ACTION_STOP = "stop"
        fun start(context: Context) = context.startForegroundService(Intent(context, ParentService::class.java))
        fun stop(context: Context) = context.stopService(Intent(context, ParentService::class.java))
    }
}
