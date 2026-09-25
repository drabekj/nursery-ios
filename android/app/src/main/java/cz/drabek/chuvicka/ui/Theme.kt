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
import kotlin.math.max

/** The palette of the iOS app: calm night blues, a moon yellow, and warm colours for sound. */
data class Palette(
    val sky: Color, val card: Color, val ink: Color, val muted: Color,
    val moon: Color, val accent: Color, val calm: Color, val warn: Color,
    val alarm: Color, val loud: Color, val middle: Color, val neutral: Color,
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
)

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

/** The colour of one bar: a louder sound is warmer. */
fun Palette.level(v: Float): Color = when {
    v < 0.35f -> calm
    v < 0.7f -> middle
    else -> loud
}

/** The last 6 seconds of sound, as bars from the middle. */
@Composable
fun Waveform(history: List<Float>, modifier: Modifier = Modifier, dim: Boolean = false) {
    val p = colors
    Canvas(modifier.fillMaxWidth()) {
        val n = history.size
        val gap = size.width / n
        val bar = max(2f, gap * 0.45f)
        for ((i, v) in history.withIndex()) {
            val h = max(bar, v * size.height)
            val alpha = if (dim) 0.35f else 0.35f + 0.65f * (i.toFloat() / n)
            drawRoundRect(
                color = (if (dim) p.neutral else p.level(v)).copy(alpha = alpha),
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
