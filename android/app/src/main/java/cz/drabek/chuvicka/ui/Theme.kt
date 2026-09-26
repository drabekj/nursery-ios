package cz.drabek.chuvicka.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import cz.drabek.chuvicka.Settings
import cz.drabek.chuvicka.parent.RoomState
import kotlin.math.max

/** The palette of the iOS app: calm night blues, a moon yellow, and warm colours for sound. */
data class Palette(
    val sky: Color, val card: Color, val ink: Color, val muted: Color,
    val moon: Color, val accent: Color, val calm: Color, val warn: Color,
    val alarm: Color, val loud: Color, val middle: Color, val neutral: Color,
    /** The dark appearance: the fields use the dark tokens, with white type on all. */
    val dark: Boolean = false,
)

val LightPalette = Palette(
    sky = Color(0xFFF6F8FC), card = Color(0xFFFFFFFF), ink = Color(0xFF141A2B), muted = Color(0xFF5E6679),
    moon = Color(0xFFF5CF6E), accent = Color(0xFFA86B0C), calm = Color(0xFF1C9A6C), warn = Color(0xFFD27D12),
    alarm = Color(0xFFD8433D), loud = Color(0xFFE0613F), middle = Color(0xFFE3A020), neutral = Color(0xFF9AA3B8),
)

val DarkPalette = Palette(
    sky = Color(0xFF090E1F), card = Color(0xFF151B33), ink = Color(0xFFEEF1F8), muted = Color(0xFF9AA3B8),
    moon = Color(0xFFF7D98C), accent = Color(0xFFF7D98C), calm = Color(0xFF73E3B8), warn = Color(0xFFFFB861),
    alarm = Color(0xFFFF6B6B), loud = Color(0xFFFF9973), middle = Color(0xFFF7D98C), neutral = Color(0xFF5A6070),
    dark = true,
)

/**
 * The colours of the room state: the field behind the glance view, the band and the frame of the
 * picture view, the waveform bars. The same values as on the iPhone. They never change with the
 * wallpaper: no dynamic colour, so a purple wallpaper does not give a purple „Klid".
 */
object StateColors {
    // Light fields: a lit room, by day.
    val calm = Color(0xFF00A1A0)          // teal, white type
    val sound = Color(0xFFFBC040)         // amber, ink type
    val cry = Color(0xFFA81233)           // wine, white type
    val graphite = Color(0xFF3A3D45)      // lost and connecting, white type
    // Dark fields: the dark appearance, and the light one after 30 s untouched. White type on all.
    val calmDim = Color(0xFF117376)
    val soundDim = Color(0xFF78662E)
    val cryDim = Color(0xFF570F29)
    val graphiteDim = Color(0xFF2A2C33)
    /** The type on amber. White there would be about 2:1. */
    val ink = Color(0xFF1B1B1F)
    /** The ribbon (muted, volume low, a short gap): never a field colour. White type, 5.4:1. */
    val ribbon = Color(0xFF5C6B8A)
    /** The glyph of „Nehlídá" on graphite: the dark-mode alarm red, 4.0:1. */
    val lostGlyph = Color(0xFFFF6B6B)
    /** On black, in Night mode: the state colour as a dim accent. Wine is too dark on black. */
    val cryNight = Color(0xFFC64B70)
}

/** The field of a state. [dim]: after 30 s untouched. The dark appearance is always dim. */
fun Palette.field(state: RoomState, dim: Boolean = false): Color {
    val d = dim || dark
    return when (state) {
        RoomState.CALM -> if (d) StateColors.calmDim else StateColors.calm
        RoomState.SOUND -> if (d) StateColors.soundDim else StateColors.sound
        RoomState.CRY -> if (d) StateColors.cryDim else StateColors.cry
        RoomState.LOST, RoomState.CONNECTING -> if (d) StateColors.graphiteDim else StateColors.graphite
    }
}

/** The glyph and the word on a field: white, only ink on the bright amber. */
fun Palette.onField(state: RoomState, dim: Boolean = false): Color =
    if (state == RoomState.SOUND && !dim && !dark) StateColors.ink else Color.White

/** Small text on a field: white 90 %, ink 70 % on amber. Aims at 4.5:1. */
fun Palette.onFieldSecondary(state: RoomState, dim: Boolean = false): Color {
    val on = onField(state, dim)
    return on.copy(alpha = if (on == Color.White) 0.9f else 0.7f)
}

/** The state colour on black (Night mode), before the alpha of the glyph or the word. */
fun nightAccent(state: RoomState): Color = when (state) {
    RoomState.CALM -> StateColors.calm
    RoomState.SOUND -> StateColors.sound
    RoomState.CRY -> StateColors.cryNight
    RoomState.LOST -> StateColors.lostGlyph
    RoomState.CONNECTING -> Color.White
}

val LocalPalette = staticCompositionLocalOf { LightPalette }

val colors: Palette @Composable get() = LocalPalette.current

@Composable
fun ChuvickaTheme(appearance: Settings.Appearance, forceDark: Boolean = false, content: @Composable () -> Unit) {
    val dark = forceDark || when (appearance) {
        Settings.Appearance.LIGHT -> false
        Settings.Appearance.DARK -> true
        Settings.Appearance.AUTO -> isSystemInDarkTheme()
    }
    val p = if (dark) DarkPalette else LightPalette
    val scheme = if (dark) darkColorScheme(
        primary = p.moon, onPrimary = Color.Black, background = p.sky, surface = p.card,
        onBackground = p.ink, onSurface = p.ink, error = p.alarm, secondary = p.accent,
    ) else lightColorScheme(
        primary = p.accent, onPrimary = Color.White, background = p.sky, surface = p.card,
        onBackground = p.ink, onSurface = p.ink, error = p.alarm, secondary = p.accent,
    )
    CompositionLocalProvider(LocalPalette provides p) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}

/** The colour of one bar: the colours of the states, so the waveform and the field agree. */
fun Palette.level(v: Float): Color = when {
    v < 0.35f -> StateColors.calm
    v < 0.7f -> if (dark) StateColors.sound else Color(0xFFE3A020)    // A deeper amber reads on the light sky.
    else -> if (dark) StateColors.cryNight else StateColors.cry
}

/**
 * The last 6 seconds of sound, as bars from the middle. [tint]: one colour for all bars, for a
 * waveform on a field (teal bars on a teal field would not show); the height carries the level.
 */
@Composable
fun Waveform(history: List<Float>, modifier: Modifier = Modifier, dim: Boolean = false, tint: Color? = null) {
    val p = colors
    Canvas(modifier.fillMaxWidth()) {
        val n = history.size
        val gap = size.width / n
        val bar = max(2f, gap * 0.45f)
        for ((i, v) in history.withIndex()) {
            val h = max(bar, v * size.height)
            val alpha = if (dim) 0.35f else 0.35f + 0.65f * (i.toFloat() / n)
            drawRoundRect(
                color = (tint ?: if (dim) p.neutral else p.level(v)).copy(alpha = alpha),
                topLeft = Offset(i * gap + (gap - bar) / 2, (size.height - h) / 2),
                size = Size(bar, h),
                cornerRadius = CornerRadius(bar / 2, bar / 2),
            )
        }
    }
}

/** "před 7 s", "před 3 min": the Czech relative form. */
fun ago(millis: Long, now: Long = System.currentTimeMillis()): String {
    val s = max(0L, (now - millis) / 1000)
    return when {
        s < 60 -> "před $s s"
        s < 3600 -> "před ${s / 60} min"
        else -> "před ${s / 3600} h"
    }
}
