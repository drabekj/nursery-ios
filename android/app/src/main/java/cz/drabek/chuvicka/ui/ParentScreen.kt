package cz.drabek.chuvicka.ui

import android.graphics.BitmapFactory
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.PictureInPictureAlt
import androidx.compose.material.icons.filled.PowerSettingsNew
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import cz.drabek.chuvicka.App
import cz.drabek.chuvicka.R
import cz.drabek.chuvicka.Settings
import cz.drabek.chuvicka.parent.Connection
import cz.drabek.chuvicka.parent.Monitor
import cz.drabek.chuvicka.parent.SoundMode
import cz.drabek.chuvicka.parent.SoundStatus
import cz.drabek.chuvicka.parent.VideoDecoder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun ParentScreen(openSettings: () -> Unit, pip: Boolean, enterPip: () -> Unit) {
    val soundView by Settings.soundView.collectAsState()
    val night by Monitor.night.collectAsState()
    val view = LocalView.current
    DisposableEffect(Unit) {
        view.keepScreenOn = true
        onDispose { view.keepScreenOn = false }
    }
    if (pip) { VideoSurface(Modifier.fillMaxSize()); return }
    val paused by Monitor.paused.collectAsState()
    val context = androidx.compose.ui.platform.LocalContext.current
    if (paused) {
        PausedScreen { Monitor.paused.value = false; cz.drabek.chuvicka.parent.ParentService.start(context) }
        return
    }
    Box(Modifier.fillMaxSize().background(colors.sky)) {
        Column(Modifier.fillMaxSize().systemBarsPadding().padding(horizontal = 16.dp)) {
            TopRow(openSettings)
            ViewSwitch(soundView) { on ->
                Settings.set(Settings.soundView, "soundView", on)
                Monitor.reconnect(if (on) "sound view" else "picture view")
            }
            Spacer(Modifier.height(16.dp))
            AnimatedContent(soundView, Modifier.weight(1f), transitionSpec = { fadeIn(tween(350)) togetherWith fadeOut(tween(200)) }, label = "view") { sound ->
                if (sound) SoundStage() else PictureStage(enterPip)
            }
            Spacer(Modifier.height(12.dp))
            VolumeWarning()
            ControlBar()
            Spacer(Modifier.height(8.dp))
        }
        AnimatedVisibility(night, enter = fadeIn(tween(500)), exit = fadeOut(tween(500))) {
            NightScreen { Monitor.night.value = false; Monitor.reconnect("night mode off") }
        }
    }
}

@Composable
private fun TopRow(openSettings: () -> Unit) {
    val connection by Monitor.connection.collectAsState()
    val pictureLive by Monitor.pictureLive.collectAsState()
    val soundView by Settings.soundView.collectAsState()
    val (text, color) = when (val c = connection) {
        Connection.Live -> (if (pictureLive || soundView) "Živě" else "Čekání na obraz") to (if (pictureLive || soundView) colors.alarm else colors.warn)
        Connection.Connecting, Connection.Idle -> "Připojování" to colors.warn
        is Connection.Retrying -> (if (c.failures >= 2) "Nedostupné" else "Obnovování spojení") to (if (c.failures >= 2) colors.neutral else colors.warn)
    }
    Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.clip(RoundedCornerShape(50)).background(colors.card).padding(horizontal = 14.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(9.dp).clip(CircleShape).background(color))
            Spacer(Modifier.width(8.dp))
            Text(text, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, color = colors.ink)
        }
        Text("Chůvička", Modifier.weight(1f), textAlign = TextAlign.Center, fontWeight = FontWeight.SemiBold, fontSize = 18.sp, color = colors.ink)
        val context = androidx.compose.ui.platform.LocalContext.current
        // The clear way to stop: no sound, no stream, no notification.
        IconButton(onClick = {
            Monitor.night.value = false
            Monitor.paused.value = true
            cz.drabek.chuvicka.parent.ParentService.stop(context)
        }, Modifier.clip(CircleShape).background(colors.card)) {
            Icon(Icons.Filled.PowerSettingsNew, "Ukončit hlídání", tint = colors.alarm)
        }
        Spacer(Modifier.width(8.dp))
        IconButton(onClick = openSettings, Modifier.clip(CircleShape).background(colors.card)) {
            Icon(Icons.Filled.Settings, "Nastavení", tint = colors.accent)
        }
    }
}

/** "Obraz | Jen zvuk". The chosen side is filled with the moon colour. */
@Composable
fun ViewSwitch(soundView: Boolean, choose: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().wrapContentWidth().clip(RoundedCornerShape(50)).background(colors.card).padding(4.dp)) {
        Segment(!soundView, Icons.Filled.Videocam, "Obraz") { choose(false) }
        Segment(soundView, Icons.Filled.GraphicEq, "Jen zvuk") { choose(true) }
    }
}

@Composable
private fun Segment(selected: Boolean, icon: ImageVector, title: String, onClick: () -> Unit) {
    val bg by animateColorAsState(if (selected) colors.moon else Color.Transparent, tween(250), label = "segment")
    Row(Modifier.clip(RoundedCornerShape(50)).background(bg).clickable(enabled = !selected, onClick = onClick)
        .padding(horizontal = 18.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(18.dp), tint = if (selected) Color.Black else colors.ink)
        Spacer(Modifier.width(8.dp))
        Text(title, fontWeight = FontWeight.SemiBold, color = if (selected) Color.Black else colors.ink)
    }
}

// MARK: The picture view

@Composable
private fun PictureStage(enterPip: () -> Unit) {
    val (w, h) = Monitor.videoSize.collectAsState().value
    val pictureLive by Monitor.pictureLive.collectAsState()
    Column {
        Box(Modifier.fillMaxWidth().aspectRatio(w.toFloat() / maxOf(h, 1)).clip(RoundedCornerShape(26.dp)).background(Color.Black)) {
            VideoSurface(Modifier.fillMaxSize())
            if (!pictureLive) VideoPlaceholder()
            if (pictureLive && !App.demo) {
                IconButton(onClick = enterPip, Modifier.align(Alignment.BottomEnd).padding(10.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.45f))) {
                    Icon(Icons.Filled.PictureInPictureAlt, "Obraz v obraze", tint = Color.White)
                }
            }
        }
        Spacer(Modifier.height(20.dp))
        RoomWords(center = false)
        Spacer(Modifier.height(14.dp))
        Waveform(Monitor.history.collectAsState().value, Modifier.height(80.dp), dim = Monitor.status.collectAsState().value.let { it != SoundStatus.LISTENING && it != SoundStatus.SILENT })
    }
}

/** The decoder draws straight on this surface. In the demo, a still picture. */
@Composable
fun VideoSurface(modifier: Modifier) {
    if (App.demo) {
        Image(painterResource(R.drawable.demo_frame), null, modifier, contentScale = ContentScale.Crop)
        return
    }
    AndroidView(factory = { ctx ->
        SurfaceView(ctx).apply {
            holder.addCallback(object : SurfaceHolder.Callback {
                var decoder: VideoDecoder? = null
                override fun surfaceCreated(h: SurfaceHolder) {
                    val d = VideoDecoder(h.surface) { vw, vh -> Monitor.videoSize.value = vw to vh }
                    decoder = d
                    Monitor.videoSink = { unit, dep -> d.push(unit, dep) }
                }
                override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, hh: Int) {}
                override fun surfaceDestroyed(h: SurfaceHolder) {
                    Monitor.videoSink = null
                    decoder?.release()
                    decoder = null
                }
            })
        }
    }, modifier = modifier)
}

@Composable
private fun VideoPlaceholder() {
    val connection by Monitor.connection.collectAsState()
    val source by Settings.source.collectAsState()
    Column(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.8f)).padding(20.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        val c = connection
        if (c is Connection.Retrying && c.failures >= 2) {
            Icon(Icons.Filled.WifiOff, null, tint = colors.alarm, modifier = Modifier.size(30.dp))
            Spacer(Modifier.height(8.dp))
            Text(if (source == Settings.Source.PHONE) "Telefon u miminka je nedostupný" else "Kamera je nedostupná",
                color = Color.White, fontWeight = FontWeight.SemiBold)
            Text(c.why, color = Color.White.copy(alpha = 0.6f), fontSize = 12.sp, textAlign = TextAlign.Center)
            Spacer(Modifier.height(8.dp))
            Button(onClick = { Monitor.reconnect("user asked") }) { Text("Zkusit znovu") }
        } else {
            CircularProgressIndicator(color = Color.White)
            Spacer(Modifier.height(10.dp))
            Text(when {
                c == Connection.Live && source == Settings.Source.PHONE -> "Obraz stojí. Je telefon u miminka zapnutý?"
                c is Connection.Retrying -> "Obnovování spojení…"
                source == Settings.Source.PHONE -> "Připojování k telefonu u miminka…"
                else -> "Připojování ke kameře…"
            }, color = Color.White.copy(alpha = 0.7f), textAlign = TextAlign.Center)
        }
    }
}

// MARK: The sound view

@Composable
private fun SoundStage() {
    val mode by Monitor.mode.collectAsState()
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
            Orb(Modifier.fillMaxHeight().aspectRatio(1f).widthIn(max = 280.dp)
                .clickable(enabled = mode == SoundMode.OFF, onClickLabel = "Zapnout zvuk") { Monitor.setMode(SoundMode.LIVE) })
        }
        Spacer(Modifier.height(12.dp))
        RoomWords(center = true)
        Spacer(Modifier.height(18.dp))
        PeekCard()
    }
}

/** The room as one calm shape: rings that ripple with the sound, a slow breath when quiet. */
@Composable
private fun Orb(modifier: Modifier) {
    val history by Monitor.history.collectAsState()
    val status by Monitor.status.collectAsState()
    val soundNow by Monitor.soundNow.collectAsState()
    val p = colors
    val breath by rememberInfiniteTransition(label = "breath").animateFloat(0.975f, 1.035f,
        infiniteRepeatable(tween(5000), RepeatMode.Reverse), label = "breath")
    val hears = status == SoundStatus.LISTENING || status == SoundStatus.SILENT
    fun value(ago: Int) = if (hears) history[history.size - 1 - ago] else 0f
    fun color(v: Float) = when (status) {
        SoundStatus.LOST, SoundStatus.MUTED -> p.alarm
        SoundStatus.CONNECTING -> p.neutral
        else -> p.level(v)
    }
    Box(modifier.scale(if (soundNow || !hears) 1f else breath), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val d = size.minDimension
            val core = d * 0.44f
            for (i in 3 downTo 1) {
                val v = value((i - 1) * 4)
                val spread = (d - core) * i / 3f * (0.4f + 0.6f * v)
                drawCircle(color(v).copy(alpha = 0.2f - i * 0.045f), radius = (core + spread) / 2)
            }
            drawCircle(color(value(0)).copy(alpha = 0.3f), radius = core / 2)
        }
        Icon(when (status) {
            SoundStatus.MUTED -> Icons.AutoMirrored.Filled.VolumeOff
            SoundStatus.LOST -> Icons.Filled.WifiOff
            else -> if (soundNow) Icons.Filled.GraphicEq else Icons.Filled.Bedtime
        }, null, Modifier.fillMaxSize(0.14f), tint = if (status == SoundStatus.MUTED || status == SoundStatus.LOST) p.alarm else p.ink.copy(alpha = 0.55f))
    }
}

/** One photo of the cot, on request: no live picture, no battery cost. */
@Composable
private fun PeekCard() {
    var image by remember { mutableStateOf<android.graphics.Bitmap?>(null) }
    var taken by remember { mutableStateOf(0L) }
    var loading by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    var unavailable by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    fun peek() {
        // An IP camera read directly gives no photo: only the live picture.
        if (!App.demo && Settings.source.value == Settings.Source.CAMERA && Settings.cameraKind.value == Settings.KIND_RTSP) {
            unavailable = true; return
        }
        loading = true; failed = false
        scope.launch {
            val bytes = withContext(Dispatchers.IO) { Monitor.snapshot() }
            val bmp = if (App.demo) null else bytes?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
            loading = false
            if (bmp != null || App.demo) { image = bmp; taken = System.currentTimeMillis() } else failed = true
        }
    }
    LaunchedEffect(Unit) { if (App.demo) peek() }
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(colors.card).clickable(enabled = !loading) { peek() }.padding(12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(96.dp, 54.dp).clip(RoundedCornerShape(12.dp)).background(colors.neutral.copy(alpha = 0.15f)), contentAlignment = Alignment.Center) {
            when {
                image != null -> Image(image!!.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                App.demo && taken > 0 -> Image(painterResource(R.drawable.demo_frame), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                loading -> CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp)
                else -> Icon(Icons.Filled.Visibility, null, tint = colors.muted)
            }
        }
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(if (taken > 0) "Fotka z kamery" else "Nahlédnout do postýlky", fontWeight = FontWeight.SemiBold, color = colors.ink)
            val sub = when {
                unavailable -> "Fotka není k dispozici. Klepněte na živý obraz."
                failed -> "Kamera neodpověděla. Zkuste to znovu."
                loading -> "Fotím…"
                taken > 0 -> "${ago(taken)} · klepnutím obnovíte"
                else -> "Jedna fotka, bez živého obrazu"
            }
            Text(sub, fontSize = 13.sp, color = if (failed) colors.alarm else colors.muted)
        }
        IconButton(onClick = { Settings.set(Settings.soundView, "soundView", false); Monitor.reconnect("picture view") },
            Modifier.clip(CircleShape).background(colors.sky)) {
            Icon(Icons.Filled.Videocam, "Živý obraz", tint = colors.ink)
        }
    }
}

// MARK: The words, the controls, the warnings

@Composable
private fun RoomWords(center: Boolean) {
    val status by Monitor.status.collectAsState()
    val room by Monitor.roomLevel.collectAsState()
    val mode by Monitor.mode.collectAsState()
    val soundNow by Monitor.soundNow.collectAsState()
    val lastSound by Monitor.lastSound.collectAsState()
    val loudness by Settings.loudness.collectAsState()
    val soundView by Settings.soundView.collectAsState()
    val headline = when (status) {
        SoundStatus.LISTENING, SoundStatus.SILENT -> room.title
        SoundStatus.CONNECTING -> "Připojování"
        SoundStatus.LOST -> "Zvuk vypadl"
        SoundStatus.MUTED -> "Zvuk vypnut"
    }
    val sub = when (status) {
        SoundStatus.LISTENING -> if (loudness == Settings.Loudness.NORMAL) "Živý zvuk" else "Živý zvuk · ${loudness.title} +${loudness.decibels.toInt()} dB"
        SoundStatus.SILENT -> if (soundView) "Ztlumeno · při pláči přijde upozornění\nZvuk zapnete klepnutím na kruh" else "Ztlumeno · při pláči přijde upozornění"
        SoundStatus.CONNECTING -> "Spouštění živého zvuku…"
        SoundStatus.LOST -> "Obnovování spojení…"
        SoundStatus.MUTED -> if (soundView) "Zapnete ho klepnutím na kruh" else "Zapnete ho tlačítkem Zvuk"
    }
    var now by remember { mutableStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { delay(1000); now = System.currentTimeMillis() } }
    val last = when {
        soundNow -> "Ozývá se"
        lastSound != null -> "Poslední zvuk ${ago(lastSound!!, now)}"
        else -> "Zatím žádný zvuk"
    }
    val headColor = when (status) { SoundStatus.LOST -> colors.alarm; SoundStatus.MUTED, SoundStatus.CONNECTING -> colors.muted; else -> colors.ink }
    Column(Modifier.fillMaxWidth(), horizontalAlignment = if (center) Alignment.CenterHorizontally else Alignment.Start) {
        AnimatedContent(headline, transitionSpec = { fadeIn(tween(350)) togetherWith fadeOut(tween(350)) }, label = "headline") {
            Text(it, fontSize = 32.sp, fontWeight = FontWeight.SemiBold, color = headColor, textAlign = if (center) TextAlign.Center else TextAlign.Start)
        }
        Text(sub, color = colors.muted, textAlign = if (center) TextAlign.Center else TextAlign.Start)
        Spacer(Modifier.height(6.dp))
        Text(last, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = if (soundNow) colors.warn else colors.ink.copy(alpha = if (mode == SoundMode.OFF) 0.4f else 0.8f))
    }
}

/** The iPhone cannot raise the volume for the parent. Android can: the card has a button. */
@Composable
private fun VolumeWarning() {
    val volume by Monitor.volume.collectAsState()
    val mode by Monitor.mode.collectAsState()
    AnimatedVisibility(mode == SoundMode.LIVE && volume < 0.2f) {
        Row(Modifier.fillMaxWidth().padding(bottom = 12.dp).clip(RoundedCornerShape(22.dp)).background(colors.warn.copy(alpha = 0.16f)).padding(14.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Icon(if (volume < 0.01f) Icons.AutoMirrored.Filled.VolumeOff else Icons.AutoMirrored.Filled.VolumeUp, null, tint = colors.warn)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(if (volume < 0.01f) "Hlasitost telefonu je vypnutá" else "Hlasitost telefonu je nízká · ${(volume * 100).toInt()} %", fontWeight = FontWeight.SemiBold, color = colors.ink)
                Text("Pláč nemusíte slyšet.", fontSize = 13.sp, color = colors.muted)
            }
            Button(onClick = { Monitor.raiseVolume() },
                colors = ButtonDefaults.buttonColors(containerColor = colors.moon, contentColor = Color.Black)) { Text("Zesílit") }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ControlBar() {
    val mode by Monitor.mode.collectAsState()
    var menu by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.weight(1f)) {
            BarButton(
                title = when (mode) { SoundMode.LIVE -> "Zvuk"; SoundMode.OFF -> "Ztlumeno" },
                icon = when (mode) { SoundMode.LIVE -> Icons.AutoMirrored.Filled.VolumeUp; SoundMode.OFF -> Icons.AutoMirrored.Filled.VolumeOff },
                fill = if (mode == SoundMode.OFF) colors.alarm else colors.moon,     // Off is red: nothing plays.
                ink = if (mode == SoundMode.OFF) Color.White else Color.Black,
                onClick = { Monitor.setMode(if (mode == SoundMode.OFF) SoundMode.LIVE else SoundMode.OFF) },
                onLongClick = { menu = true },
            )
            DropdownMenu(menu, onDismissRequest = { menu = false }) {
                SoundMode.entries.forEach { m ->
                    DropdownMenuItem(text = { Text(m.title) }, onClick = { Monitor.setMode(m); menu = false })
                }
            }
        }
        Box(Modifier.weight(1f)) {
            BarButton("Noční", Icons.Filled.Bedtime, colors.card, colors.ink,
                onClick = { Monitor.night.value = true; Monitor.reconnect("night mode") })
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun BarButton(title: String, icon: ImageVector, fill: Color, ink: Color, onClick: () -> Unit, onLongClick: (() -> Unit)? = null) {
    Column(Modifier.fillMaxWidth().height(68.dp).clip(RoundedCornerShape(24.dp)).background(fill)
        .combinedClickable(onClick = onClick, onLongClick = onLongClick),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Icon(icon, null, tint = ink)
        Spacer(Modifier.height(4.dp))
        Text(title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = ink)
    }
}

// MARK: Night mode

/** Almost black, at the lowest brightness: the time, the sound, and the state. A tap wakes it. */
@Composable
fun NightScreen(close: () -> Unit) {
    val history by Monitor.history.collectAsState()
    val status by Monitor.status.collectAsState()
    val soundNow by Monitor.soundNow.collectAsState()
    val volume by Monitor.volume.collectAsState()
    val view = LocalView.current
    DisposableEffect(Unit) {
        // The brightness of this window only: the phone's own setting stays as it is.
        val window = (view.context as? android.app.Activity)?.window
        if (window != null && !App.demo) {
            window.attributes = window.attributes.apply { screenBrightness = 0.01f }
        }
        onDispose {
            window?.attributes = window?.attributes?.apply {
                screenBrightness = android.view.WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
            }
        }
    }
    var time by remember { mutableStateOf(Date()) }
    LaunchedEffect(Unit) { while (true) { delay(10_000); time = Date() } }
    Column(Modifier.fillMaxSize().background(Color.Black).clickable { close() }.systemBarsPadding().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Text(SimpleDateFormat("H:mm", Locale("cs")).format(time), fontSize = 72.sp, fontWeight = FontWeight.Thin, color = DarkPalette.moon.copy(alpha = 0.22f))
        Spacer(Modifier.height(24.dp))
        Box(Modifier.alpha(if (soundNow) 0.95f else 0.55f)) { Waveform(history, Modifier.height(90.dp).padding(horizontal = 16.dp), dim = !soundNow) }
        Spacer(Modifier.height(24.dp))
        val low = volume < 0.2f && status == SoundStatus.LISTENING
        Text(when { low -> "Hlasitost telefonu je nízká"; soundNow -> "Ozývá se"; else -> status.title },
            color = when { status == SoundStatus.LOST -> DarkPalette.alarm; low -> DarkPalette.warn.copy(alpha = 0.8f); else -> Color.White.copy(alpha = if (soundNow) 0.6f else 0.28f) })
        Spacer(Modifier.height(60.dp))
        Text("Můžete zhasnout displej. Zvuk poběží dál. Klepnutím Noční režim ukončíte.", fontSize = 12.sp,
            color = Color.White.copy(alpha = 0.2f), textAlign = TextAlign.Center)
    }
}

/** The monitor is off. It says so plainly, and one button starts it again. */
@Composable
private fun PausedScreen(resume: () -> Unit) {
    Column(Modifier.fillMaxSize().background(colors.sky).systemBarsPadding().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally) {
        Spacer(Modifier.weight(1f))
        Icon(Icons.Filled.Bedtime, null, Modifier.size(64.dp), tint = colors.accent)
        Spacer(Modifier.height(18.dp))
        Text("Hlídání je vypnuté", fontSize = 30.sp, fontWeight = FontWeight.Bold, color = colors.ink, textAlign = TextAlign.Center)
        Spacer(Modifier.height(10.dp))
        Text("Chůvička teď neposlouchá a nic nevysílá. Můžete ji klidně zavřít.", color = colors.muted, textAlign = TextAlign.Center)
        Spacer(Modifier.weight(1f))
        Button(onClick = resume, Modifier.fillMaxWidth().height(58.dp), shape = RoundedCornerShape(20.dp),
            colors = ButtonDefaults.buttonColors(containerColor = colors.moon, contentColor = Color.Black)) {
            Text("Znovu hlídat", fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
        }
    }
}
