package cz.drabek.chuvicka.parent

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import cz.drabek.chuvicka.App
import cz.drabek.chuvicka.MainActivity
import cz.drabek.chuvicka.R

/** The alerts: a lost connection, and a sound in the silent mode. */
object Alerts {
    private const val LOSS = 10
    private const val SOUND = 11
    private var lastSound = 0L

    fun loss(context: Context) = post(context, LOSS, "Spojení s pokojíčkem se přerušilo",
        "Chůvička se sama připojí znovu. Zkontrolujte kameru nebo telefon u miminka.")

    fun clearLoss(context: Context) = context.getSystemService(NotificationManager::class.java).cancel(LOSS)

    fun sound(context: Context) {
        val now = System.currentTimeMillis()
        if (now - lastSound < 60_000) return            // At most one a minute.
        lastSound = now
        post(context, SOUND, "Miminko se ozvalo", "Klepnutím otevřete Chůvičku.")
    }

    private fun post(context: Context, id: Int, title: String, text: String) {
        val open = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(context, App.CHANNEL_ALERTS)
            .setSmallIcon(R.drawable.ic_stat)
            .setContentTitle(title)
            .setContentText(text)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setAutoCancel(true)
            .setContentIntent(open)
            .build()
        try {
            context.getSystemService(NotificationManager::class.java).notify(id, n)
        } catch (_: SecurityException) {
            // No permission for notifications.
        }
    }
}
