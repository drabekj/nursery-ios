package cz.drabek.chuvicka.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.VolumeDown
import androidx.compose.material.icons.automirrored.rounded.VolumeOff
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.SettingsInputAntenna
import androidx.compose.material.icons.rounded.WifiOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cz.drabek.chuvicka.Settings
import cz.drabek.chuvicka.parent.Monitor
import cz.drabek.chuvicka.parent.RoomLevel
import cz.drabek.chuvicka.parent.RoomState
import cz.drabek.chuvicka.parent.SoundMode
import cz.drabek.chuvicka.parent.SoundStatus
import kotlinx.coroutines.delay
import java.util.Locale
import kotlin.math.max

// The room state as a lamp: a full-bleed colour field, one glyph, one big word, one line under it.
// The same parts make the band of the picture view and the state block of Night mode.

/** A modifier under the word: why the parent may not hear the room. Never a field colour. */
enum class RibbonKind { VOLUME, MUTED, GAP }

data class Ribbon(val kind: RibbonKind, val text: String)

/** Everything the field shows, at one moment. */
@Immutable
data class RoomView(val state: RoomState, val word: String, val subline: String, val ribbon: Ribbon?)

/** The room view from the engine. It recomposes once a second, for the durations. */
@Composable
fun roomView(): RoomView {
    val state by Monitor.roomState.collectAsState()
    val since by Monitor.roomStateSince.collectAsState()
    val lastEventEnd by Monitor.lastEventEnd.collectAsState()
    val room by Monitor.roomLevel.collectAsState()
    val status by Monitor.status.collectAsState()
    val mode by Monitor.mode.collectAsState()
    val volume by Monitor.volume.collectAsState()
    val source by Settings.source.collectAsState()
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { delay(1000); now = System.currentTimeMillis() } }
    val heard = status == SoundStatus.LISTENING || status == SoundStatus.SILENT
    val ribbon = when {
        // Volume low wins over muted: muted plays nothing anyway, so only one can be true.
        mode == SoundMode.LIVE && volume < 0.2f && heard ->
            Ribbon(RibbonKind.VOLUME, "Hlasitost telefonu ${(volume * 100).toInt()} % · pláč neuslyšíte")
        mode == SoundMode.OFF -> Ribbon(RibbonKind.MUTED, "Ztlumeno · při pláči přijde upozornění")
        // A short gap: the state stays, the ribbon says the app reconnects.
        !heard && state != RoomState.LOST && state != RoomState.CONNECTING -> Ribbon(RibbonKind.GAP, "Připojuji…")
        else -> null
    }
    return RoomView(state, state.title, subline(state, now, since, lastEventEnd, room, source == Settings.Source.CAMERA), ribbon)
}

/** The line under the word. Pure, for the field, the band, and Night mode. */
fun subline(state: RoomState, now: Long, since: Long, lastEventEnd: Long?, level: RoomLevel, camera: Boolean): String = when (state) {
    RoomState.CALM -> {
        // Quiet since the end of the last sound event, or since the start without one.
        val quiet = now - (lastEventEnd ?: since)
        val head = if (lastEventEnd == null) "ticho od začátku" else "ticho už ${span(quiet)}"
        // An inference, so it is in the small line and says "nejspíš". The big word stays "Klid".
        if (quiet >= 15 * 60_000L) "$head · nejspíš spí" else head
    }
    RoomState.SOUND -> maxOf(level, RoomLevel.SOME).title.lowercase(Locale("cs"))
    RoomState.CRY -> "${maxOf(level, RoomLevel.SOME).title.lowercase(Locale("cs"))} · už ${span(now - since)}"
    // The state turns to lost 20 s after the sound stopped: the connection fell 20 s earlier.
    RoomState.LOST -> "spojení vypadlo před ${span(now - since + 20_000)} · zkouší se znovu"
    RoomState.CONNECTING -> if (camera) "hledám kameru" else "hledám telefon u miminka"
}

/** "38 s", "42 min", "2 h 5 min". */
fun span(millis: Long): String {
    val s = max(0L, millis / 1000)
    return when {
        s < 60 -> "$s s"
        s < 3600 -> "${s / 60} min"
        else -> if ((s / 60) % 60 == 0L) "${s / 3600} h" else "${s / 3600} h ${(s / 60) % 60} min"
    }
}

/** The system switch "Remove animations" (animator duration scale 0). Then nothing moves. */
@Composable
fun reduceMotion(): Boolean {
    val context = LocalContext.current
    return remember {
        android.provider.Settings.Global.getFloat(context.contentResolver,
            android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
}

/** The field: one static radial gradient, the core 8 % lighter at 40 % of the height. Cached until the colour or the size changes. */
fun Modifier.fieldBackground(color: Color): Modifier = drawWithCache {
    val brush = Brush.radialGradient(
        listOf(lerp(color, Color.White, 0.08f), color),
        center = Offset(size.width / 2, size.height * 0.4f),
        radius = max(size.width, size.height) * 0.8f,
    )
    onDrawBehind { drawRect(brush) }
}

// MARK: The glyph

/**
 * The glyph of a state. The silhouettes differ, so the state reads at 4 m and without motion:
 * Klid a hollow ring with the moon, Ozývá se bare bars, Pláče a solid disc with the bars cut out,
 * Nehlídá a hollow ring with a red sign, Připojuji… an antenna.
 * [diameter] is the ring; the disc is 184/160 of it. [on]: the glyph colour; [hole]: the bars in the
 * disc (the field colour, or black at night); [alert]: the sign of Nehlídá.
 * One motion per state, none when [animate] is false.
 */
@Composable
fun StateGlyph(
    state: RoomState, diameter: Dp, on: Color, hole: Color, animate: Boolean, modifier: Modifier = Modifier,
    alert: Color = StateColors.lostGlyph, description: String? = state.title,
) {
    // One box for all states, big enough for the pulsing disc: the word under it does not jump.
    Box(modifier.size(diameter * 1.2f), contentAlignment = Alignment.Center) {
        when (state) {
            RoomState.CALM -> Ring(diameter, on, Icons.Rounded.Bedtime, on, description, breathe = animate)
            RoomState.LOST -> Ring(diameter, on, Icons.Rounded.WifiOff, alert, description, breathe = false)
            RoomState.SOUND -> Bars(diameter, on, description, animate)
            RoomState.CRY -> Disc(diameter, on, hole, description, animate)
            RoomState.CONNECTING -> Icon(Icons.Rounded.SettingsInputAntenna, description,
                Modifier.size(diameter * 100f / 160f), tint = on.copy(alpha = on.alpha * 0.9f))
        }
    }
}

/** A hollow ring: stroke 6/160 of the diameter, fill 22 %. Klid breathes (the old 10 s breath). */
@Composable
private fun Ring(diameter: Dp, on: Color, icon: androidx.compose.ui.graphics.vector.ImageVector, tint: Color, description: String?, breathe: Boolean) {
    val breath: State<Float>? = if (breathe) rememberInfiniteTransition(label = "breath").animateFloat(0.975f, 1.035f,
        infiniteRepeatable(tween(5000), RepeatMode.Reverse), label = "breath") else null
    Box(Modifier.size(diameter)
        // Read in the layer only: the breath redraws the layer, it does not recompose.
        .graphicsLayer { val b = breath?.value ?: 1f; scaleX = b; scaleY = b }
        .drawBehind {
            val stroke = size.minDimension * 6f / 160f
            drawCircle(on.copy(alpha = on.alpha * 0.22f))
            drawCircle(on, radius = size.minDimension / 2 - stroke / 2, style = Stroke(stroke))
        }, contentAlignment = Alignment.Center) {
        Icon(icon, description, Modifier.size(diameter * 0.55f), tint = tint)
    }
}

/** Bare bars, no circle. While a sound runs, ripples inside the glyph follow the level (10 Hz). */
@Composable
private fun Bars(diameter: Dp, on: Color, description: String?, animate: Boolean) {
    val history = Monitor.history.collectAsState()
    val box = diameter * 100f / 160f
    Box(Modifier.size(box).clipToBounds(), contentAlignment = Alignment.Center) {
        if (animate) Canvas(Modifier.matchParentSize()) {
            // Read in the draw only: 10 redraws a second, no recomposition.
            val h = history.value
            for (i in 0..2) {
                val v = h[h.size - 1 - i * 4].coerceIn(0f, 1f)
                drawCircle(on.copy(alpha = on.alpha * (0.16f - i * 0.04f) * v),
                    radius = size.minDimension / 2 * (0.4f + 0.6f * v) * (1f - i * 0.18f))
            }
        }
        Icon(Icons.Rounded.GraphicEq, description, Modifier.fillMaxSize()
            .graphicsLayer { if (animate) scaleY = 0.9f + 0.2f * history.value.last().coerceIn(0f, 1f) }, tint = on)
    }
}

/** The solid disc with the bars in the field colour: the lamp switched on. It pulses 1.00–1.06 every 1.2 s. */
@Composable
private fun Disc(diameter: Dp, on: Color, hole: Color, description: String?, animate: Boolean) {
    val pulse: State<Float>? = if (animate) rememberInfiniteTransition(label = "cry").animateFloat(1f, 1.06f,
        infiniteRepeatable(tween(600, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "cry") else null
    Box(Modifier.size(diameter * 184f / 160f)
        // Compositor only: the scale is read in the layer.
        .graphicsLayer { val s = pulse?.value ?: 1f; scaleX = s; scaleY = s }
        .background(on, CircleShape), contentAlignment = Alignment.Center) {
        Icon(Icons.Rounded.GraphicEq, description, Modifier.size(diameter * 0.66f), tint = hole)
    }
}

// MARK: The word

/**
 * One line of display type that shrinks until it fits, from [maxSize] down to [minSize].
 * Foundation 1.7 (BOM 2024.12) has no autoSize for BasicText, so: measure, shrink, draw when it fits.
 */
@Composable
fun FitText(text: String, maxSize: TextUnit, minSize: TextUnit, color: Color, modifier: Modifier = Modifier,
            weight: FontWeight = FontWeight.Bold, textAlign: TextAlign = TextAlign.Center) {
    var size by remember(text, maxSize) { mutableStateOf(maxSize) }
    var ready by remember(text, maxSize) { mutableStateOf(false) }
    Text(text, modifier.drawWithContent { if (ready) drawContent() }, color = color, fontSize = size, fontWeight = weight,
        lineHeight = size * 1.15f, textAlign = textAlign, maxLines = 1, softWrap = false, overflow = TextOverflow.Ellipsis,
        onTextLayout = { r ->
            if (r.hasVisualOverflow && size.value > minSize.value) size = max(minSize.value, size.value * 0.9f).sp
            else ready = true
        })
}

// MARK: The field (the glance view)

/**
 * The glyph, the word, the line under it, and the ribbon slot, on the field that the screen draws
 * behind (full bleed, under the status bar too). [dim]: the dim tokens after 30 s untouched.
 */
@Composable
fun StateField(view: RoomView, dim: Boolean, animate: Boolean, raiseVolume: () -> Unit, modifier: Modifier = Modifier,
               announce: Boolean = true) {
    val p = colors
    val on = p.onField(view.state, dim)
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        // One label for TalkBack: "Stav: klid, ticho už 42 min". Not live: the line changes every second.
        Column(Modifier.fillMaxWidth().clearAndSetSemantics {
            contentDescription = "Stav: ${view.word.lowercase(Locale("cs"))}, ${view.subline}"
            stateDescription = view.word
        }, horizontalAlignment = Alignment.CenterHorizontally) {
            StateGlyph(view.state, 160.dp, on, hole = p.field(view.state, dim), animate = animate)
            Spacer(Modifier.height(16.dp))
            AnimatedContent(view.word, transitionSpec = { fadeIn(tween(350)) togetherWith fadeOut(tween(350)) }, label = "word") {
                FitText(it, 96.sp, 40.sp, on, Modifier.fillMaxWidth())
            }
            Text(view.subline, Modifier.fillMaxWidth().padding(horizontal = 8.dp), fontSize = 17.sp, lineHeight = 22.sp,
                color = p.onFieldSecondary(view.state, dim), textAlign = TextAlign.Center, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        // Not under Night mode: Night mode has its own, and TalkBack would say it twice.
        if (announce) StateAnnouncer(view.state)
        Spacer(Modifier.height(14.dp))
        // The slot keeps its height, so the word does not move when a ribbon comes.
        Box(Modifier.heightIn(min = 40.dp), contentAlignment = Alignment.Center) {
            view.ribbon?.let { RibbonPill(it, raiseVolume) }
        }
    }
}

/**
 * The live region: TalkBack says only Pláče, Nehlídá, and the return to Klid. Ozývá se and
 * Připojuji… keep the last text, so a sigh says nothing.
 */
@Composable
fun StateAnnouncer(state: RoomState) {
    var announced by remember { mutableStateOf("") }
    LaunchedEffect(state) {
        if (state == RoomState.CRY || state == RoomState.LOST || state == RoomState.CALM) announced = "Stav: ${state.title.lowercase(Locale("cs"))}"
    }
    // 1 dp tall: a node of no size may be skipped by TalkBack.
    Box(Modifier.fillMaxWidth().height(1.dp).clearAndSetSemantics {
        liveRegion = LiveRegionMode.Polite
        contentDescription = announced
    })
}

/** The ribbon: slate, white type. The volume ribbon raises the volume on a tap. */
@Composable
fun RibbonPill(ribbon: Ribbon, raiseVolume: () -> Unit, modifier: Modifier = Modifier) {
    val volume = ribbon.kind == RibbonKind.VOLUME
    Row(modifier.clip(RoundedCornerShape(50)).background(StateColors.ribbon)
        .then(if (volume) Modifier.clickable(onClickLabel = "Zesílit", role = Role.Button, onClick = raiseVolume) else Modifier)
        .padding(horizontal = 14.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(when (ribbon.kind) {
            RibbonKind.VOLUME -> Icons.AutoMirrored.Rounded.VolumeDown
            RibbonKind.MUTED -> Icons.AutoMirrored.Rounded.VolumeOff
            RibbonKind.GAP -> Icons.Rounded.SettingsInputAntenna
        }, null, Modifier.size(18.dp), tint = Color.White)
        Spacer(Modifier.width(8.dp))
        Text(ribbon.text, Modifier.weight(1f, fill = false), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White, maxLines = 2)
        if (volume) {
            Spacer(Modifier.width(10.dp))
            Text("Zesílit", Modifier.clip(RoundedCornerShape(50)).background(Color.White.copy(alpha = 0.22f)).padding(horizontal = 10.dp, vertical = 4.dp),
                fontSize = 14.sp, fontWeight = FontWeight.Bold, color = Color.White)
        }
    }
}

// MARK: The band (the picture view)

/**
 * The state as a horizontal band under the video, at least 96 dp tall: glyph 44 dp, word 40 sp,
 * the line under it. The same colours as the field (dim tokens in the dark appearance).
 */
@Composable
fun StateBand(view: RoomView, animate: Boolean, modifier: Modifier = Modifier, announce: Boolean = true) {
    val p = colors
    val field = p.field(view.state)
    val on = p.onField(view.state)
    // The muted or gap ribbon becomes the line; the volume card of the picture view says the volume.
    val line = view.ribbon?.takeIf { it.kind != RibbonKind.VOLUME }?.text ?: view.subline
    Column(modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth().heightIn(min = 96.dp).clip(RoundedCornerShape(24.dp)).fieldBackground(field)
            .clearAndSetSemantics {
                contentDescription = "Stav: ${view.word.lowercase(Locale("cs"))}, $line"
                stateDescription = view.word
            }
            .padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            StateGlyph(view.state, 44.dp, on, hole = field, animate = animate)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                AnimatedContent(view.word, transitionSpec = { fadeIn(tween(350)) togetherWith fadeOut(tween(350)) }, label = "band") {
                    FitText(it, 40.sp, 24.sp, on, Modifier.fillMaxWidth(), textAlign = TextAlign.Start)
                }
                Text(line, fontSize = 15.sp, lineHeight = 19.sp, color = p.onFieldSecondary(view.state),
                    maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
        if (announce) StateAnnouncer(view.state)
    }
}
