package cz.drabek.chuvicka.parent

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import cz.drabek.chuvicka.App
import cz.drabek.chuvicka.MainActivity
import cz.drabek.chuvicka.R
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** The state colour of the notifications (the light field tokens). It tints the icon and the app name. */
val RoomState.notificationColor: Int
    get() = when (this) {
        RoomState.CALM -> 0xFF00A1A0.toInt()
        RoomState.SOUND -> 0xFFFBC040.toInt()
        RoomState.CRY -> 0xFFA81233.toInt()
        RoomState.LOST, RoomState.CONNECTING -> 0xFF3A3D45.toInt()
    }

/** The state glyph for the status bar. */
val RoomState.notificationIcon: Int
    get() = when (this) {
        RoomState.CONNECTING -> R.drawable.ic_state_connecting
        RoomState.CALM -> R.drawable.ic_state_calm
        RoomState.SOUND -> R.drawable.ic_state_sound
        RoomState.CRY -> R.drawable.ic_state_cry
        RoomState.LOST -> R.drawable.ic_state_lost
    }

/** The alerts: the cry, a sound (only when the parent asks for it), and a lost connection. */
object Alerts {
    private const val LOSS = 10
    /** One id for the sound and the cry: the card of one event upgrades from „se ozývá" to „pláče". */
    private const val SOUND = 11
    private var lastPost = 0L
    /** The event (its start) of the card now, and whether the card says „pláče". */
    private var postedEvent: Long? = null
    private var postedCry = false

    fun loss(context: Context, since: Long) = post(context, LOSS, RoomState.LOST, "Chůvička nehlídá",
        "Spojení vypadlo v ${clock(since)}. Chůvička to zkouší dál sama.")

    fun clearLoss(context: Context) = context.getSystemService(NotificationManager::class.java).cancel(LOSS)

    /** „Miminko pláče": once per event. It may replace the „se ozývá" card of the same event at once. */
    fun cry(context: Context, event: Long, level: RoomLevel) {
        val now = System.currentTimeMillis()
        if (postedEvent == event && postedCry) return
        val upgrade = postedEvent == event
        if (!upgrade && now - lastPost < 60_000) return            // At most one a minute.
        lastPost = now
        postedEvent = event
        postedCry = true
        postEvent(context, RoomState.CRY, "Miminko pláče", "od ${clock(event)} · ${level.word}")
    }

    /** „Miminko se ozývá": only with Settings.alertOnAnySound. Once per event. */
    fun sound(context: Context, event: Long, level: RoomLevel) {
        val now = System.currentTimeMillis()
        if (postedEvent == event || now - lastPost < 60_000) return
        lastPost = now
        postedEvent = event
        postedCry = false
        postEvent(context, RoomState.SOUND, "Miminko se ozývá", "v ${clock(event)} · ${level.word}")
    }

    fun clearSound(context: Context) = context.getSystemService(NotificationManager::class.java).cancel(SOUND)

    private fun postEvent(context: Context, state: RoomState, title: String, text: String) {
        // The app is open but muted: a tap turns the sound on, the app is already there.
        if (Monitor.foreground.value && Monitor.mode.value == SoundMode.OFF) {
            val unmute = PendingIntent.getService(context, 2,
                Intent(context, ParentService::class.java).setAction(ParentService.ACTION_UNMUTE), PendingIntent.FLAG_IMMUTABLE)
            post(context, SOUND, state, title, "$text · Ztlumeno, klepnutím zapnete zvuk", unmute)
        } else {
            post(context, SOUND, state, title, text)
        }
    }

    /** "3:12" */
    private fun clock(time: Long) = SimpleDateFormat("H:mm", Locale.forLanguageTag("cs")).format(Date(time))

    private fun post(context: Context, id: Int, state: RoomState, title: String, text: String, tap: PendingIntent? = null) {
        val open = tap ?: PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(context, App.CHANNEL_ALERTS)
            .setSmallIcon(state.notificationIcon)
            .setColor(state.notificationColor)
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
