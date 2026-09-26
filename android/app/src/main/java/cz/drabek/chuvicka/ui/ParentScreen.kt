package cz.drabek.chuvicka.ui

import androidx.compose.ui.platform.LocalConfiguration
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.graphics.BitmapFactory
import android.os.BatteryManager
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
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.BatteryChargingFull
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.BrightnessLow
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.OpenWith
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PictureInPictureAlt
import androidx.compose.material.icons.filled.StopCircle
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.WbSunny
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
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import cz.drabek.chuvicka.App
import cz.drabek.chuvicka.Log
import cz.drabek.chuvicka.R
import cz.drabek.chuvicka.Settings
import cz.drabek.chuvicka.parent.Connection
import cz.drabek.chuvicka.parent.Monitor
import cz.drabek.chuvicka.parent.PtzDirection
import cz.drabek.chuvicka.parent.RoomLevel
import cz.drabek.chuvicka.parent.RoomState
import cz.drabek.chuvicka.parent.SoundMode
import cz.drabek.chuvicka.parent.SoundStatus
import cz.drabek.chuvicka.parent.VideoDecoder
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

@Composable
fun ParentScreen(openSettings: () -> Unit, openHelp: () -> Unit, pip: Boolean, enterPip: () -> Unit) {
    val soundView by Settings.soundView.collectAsState()
    val night by Monitor.night.collectAsState()
    val view = LocalView.current
    DisposableEffect(Unit) {
        view.keepScreenOn = true
        onDispose { view.keepScreenOn = false }
    }
    // The main stream only sideways, where the picture is big; not in the small window. Up after 0.6 s,
    // down after 10 s, so a quick turn does not switch twice (each switch is a reconnect).
    val big = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE && !pip
    LaunchedEffect(big) { delay(if (big) 600 else 10_000); Monitor.setDetail(big) }
    if (pip) { VideoSurface(Modifier.fillMaxSize()); return }
    val paused by Monitor.paused.collectAsState()
    val context = androidx.compose.ui.platform.LocalContext.current
    // Every "Ukončit hlídání" asks first. The demo screen "stop" shows the question.
    var confirmStop by remember { mutableStateOf(App.demoScreen == "stop") }
    // "Natočit": the arrows on the picture. The demo screen "aim" shows them.
    var aiming by remember { mutableStateOf(App.demoScreen == "aim") }
    val ptzReady by Monitor.ptzReady.collectAsState()
    LaunchedEffect(soundView, night, ptzReady) { if (soundView || night || (!ptzReady && !App.demo)) aiming = false }
    val snackbar = remember { SnackbarHostState() }
    // A message of the monitor ("Kamera nalezena na nové adrese"): once, then gone.
    LaunchedEffect(Unit) {
        Monitor.notice.collect { text ->
            if (text != null) {
                Monitor.notice.value = null
                snackbar.showSnackbar(text)
            }
        }
    }
    // The field: the glance view is the state colour, edge to edge. After 30 s untouched it dims;
    // only Pláče or a touch lights it again (a sigh does not double the light in the room).
    val state by Monitor.roomState.collectAsState()
    var touches by remember { mutableIntStateOf(0) }
    var dim by remember { mutableStateOf(false) }
    val crying = state == RoomState.CRY
    LaunchedEffect(touches, crying, soundView, night) {
        dim = false
        if (soundView && !night && !crying) { delay(30_000); dim = true }
    }
    val onField = soundView && !night
    val p = colors
    val fieldColor by animateColorAsState(p.field(state, dim), tween(600), label = "field")
    val reduce = reduceMotion()
    // The status bar icons follow the field: dark only on the bright amber. Light on black in Night mode.
    val activity = view.context as? Activity
    val darkIcons = when {
        night -> false
        onField && !paused -> p.onField(state, dim) != Color.White
        else -> !p.dark
    }
    LaunchedEffect(darkIcons, p.dark) {
        activity?.window?.let { WindowCompat.getInsetsController(it, view).isAppearanceLightStatusBars = darkIcons }
    }
    val appIcons by rememberUpdatedState(!p.dark)
    DisposableEffect(Unit) {
        onDispose { activity?.window?.let { WindowCompat.getInsetsController(it, view).isAppearanceLightStatusBars = appIcons } }
    }
    NightSuggestion(night || paused, snackbar)
    if (paused) {
        PausedScreen { Monitor.paused.value = false; cz.drabek.chuvicka.parent.ParentService.start(context) }
        return
    }
    Box(Modifier.fillMaxSize()
        .then(if (onField) Modifier.fieldBackground(fieldColor) else Modifier.background(p.sky))
        // Every touch counts for the dimming. It does not take the touch from the buttons.
        .pointerInput(Unit) {
            awaitPointerEventScope {
                while (true) {
                    if (awaitPointerEvent(PointerEventPass.Initial).type == PointerEventType.Press) touches++
                }
            }
        }) {
        CompositionLocalProvider(LocalOnField provides if (onField) OnField(p.onField(state, dim), fieldColor) else null) {
            Column(Modifier.fillMaxSize().systemBarsPadding().padding(horizontal = 16.dp)) {
                TopRow(openSettings, openHelp, requestStop = { confirmStop = true })
                ViewSwitch(soundView) { on ->
                    Settings.set(Settings.soundView, "soundView", on)
                    Monitor.reconnect(if (on) "sound view" else "picture view")
                }
                Spacer(Modifier.height(16.dp))
                // Nothing moves under Night mode or with "Remove animations".
                val animate = !night && !reduce
                AnimatedContent(soundView, Modifier.weight(1f), transitionSpec = { fadeIn(tween(350)) togetherWith fadeOut(tween(200)) }, label = "view") { sound ->
                    if (sound) SoundStage(dim, animate, announce = !night)
                    else PictureStage(enterPip, aiming && !night, snackbar, animate, announce = !night) { aiming = false }
                }
                Spacer(Modifier.height(12.dp))
                // In the glance view the volume is a ribbon under the word.
                if (!soundView) VolumeWarning()
                ControlBar(aiming) { aiming = !aiming }
                Spacer(Modifier.height(8.dp))
            }
        }
        // Above the control bar; Night mode covers it.
        SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(start = 16.dp, end = 16.dp, bottom = 88.dp))
        AnimatedVisibility(night, enter = fadeIn(tween(500)), exit = fadeOut(tween(500))) {
            NightScreen(close = { Monitor.night.value = false; Monitor.reconnect("night mode off") }, requestStop = { confirmStop = true })
        }
    }
    // Also over Night mode: the one bright thing, the parent is about to leave the night anyway.
    if (confirmStop) AlertDialog(
        onDismissRequest = { confirmStop = false },
        title = { Text("Ukončit hlídání?") },
        text = { Text("Chůvička přestane poslouchat a nepřijde žádné upozornění.") },
        confirmButton = { TextButton(onClick = { confirmStop = false; stopWatching(context) }) { Text("Ukončit hlídání", color = colors.alarm) } },
        dismissButton = { TextButton(onClick = { confirmStop = false }) { Text("Zrušit") } },
    )
}

/** On a field: the type colour and the field colour. Null on the plain page (the picture view). */
private data class OnField(val on: Color, val field: Color)

private val LocalOnField = compositionLocalOf<OnField?> { null }

/** Glass on a field: translucent white. No brand yellow on a field. */
private val FieldGlass = Color.White.copy(alpha = 0.18f)

/**
 * "Je noc. Zapnout Noční režim?": after 21:00, on the charger, the monitor up 3 min. Once an evening.
 * The parent will not look for the Noční button at 2 a.m.
 */
@Composable
private fun NightSuggestion(off: Boolean, snackbar: SnackbarHostState) {
    val context = androidx.compose.ui.platform.LocalContext.current
    LaunchedEffect(off) {
        if (off || App.demo) return@LaunchedEffect
        delay(180_000)
        val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
        while (true) {
            val cal = Calendar.getInstance()
            val hour = cal.get(Calendar.HOUR_OF_DAY)
            if (hour >= 21 || hour < 5) {
                if (hour < 5) cal.add(Calendar.DAY_OF_YEAR, -1)        // After midnight: still the same evening.
                val evening = "${cal.get(Calendar.YEAR)}-${cal.get(Calendar.DAY_OF_YEAR)}"
                if (prefs.getString("nightSuggested", null) != evening && batteryNow(context).second) {
                    prefs.edit().putString("nightSuggested", evening).apply()
                    val r = snackbar.showSnackbar("Je noc. Zapnout Noční režim?", actionLabel = "Zapnout",
                        withDismissAction = true, duration = SnackbarDuration.Long)
                    if (r == SnackbarResult.ActionPerformed) { Monitor.night.value = true; Monitor.reconnect("night mode") }
                    break
                }
            }
            delay(60_000)
        }
    }
}

@Composable
private fun TopRow(openSettings: () -> Unit, openHelp: () -> Unit, requestStop: () -> Unit) {
    val connection by Monitor.connection.collectAsState()
    val pictureLive by Monitor.pictureLive.collectAsState()
    val soundView by Settings.soundView.collectAsState()
    val (text, color) = when (val c = connection) {
        Connection.Live -> (if (pictureLive || soundView) "Živě" else "Čekání na obraz") to (if (pictureLive || soundView) colors.calm else colors.warn)
        Connection.Connecting, Connection.Idle -> "Připojování" to colors.warn
        is Connection.Retrying -> (if (c.failures >= 2) "Nedostupné" else "Obnovování spojení") to (if (c.failures >= 2) colors.neutral else colors.warn)
    }
    // On a field: glass pills; the dot and the type in the field's type colour.
    val f = LocalOnField.current
    val pill = if (f != null) FieldGlass else colors.card
    val ink = f?.on ?: colors.ink
    Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.clip(RoundedCornerShape(50)).background(pill).padding(horizontal = 14.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(9.dp).clip(CircleShape).background(f?.on ?: color))
            Spacer(Modifier.width(8.dp))
            Text(text, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, color = ink)
        }
        Text("Chůvička", Modifier.weight(1f), textAlign = TextAlign.Center, fontWeight = FontWeight.SemiBold, fontSize = 18.sp, color = ink)
        var menu by remember { mutableStateOf(false) }
        Box {
            IconButton(onClick = { menu = true }, Modifier.clip(CircleShape).background(pill)) {
                Icon(Icons.Filled.MoreVert, "Další volby", tint = f?.on ?: colors.accent)
            }
            DropdownMenu(menu, onDismissRequest = { menu = false }, Modifier.background(colors.card)) {
                DropdownMenuItem(text = { Text("Nastavení") }, onClick = { menu = false; openSettings() })
                DropdownMenuItem(text = { Text("Nápověda") }, onClick = { menu = false; openHelp() })
                HorizontalDivider()
                DropdownMenuItem(text = { Text("Ukončit hlídání", color = colors.alarm) }, onClick = { menu = false; requestStop() })
            }
        }
    }
}

/** Stop the monitor: no sound, no stream, no notification. The paused screen says so. */
private fun stopWatching(context: Context) {
    Monitor.night.value = false
    Monitor.paused.value = true
    cz.drabek.chuvicka.parent.ParentService.stop(context)
}

/**
 * "Obraz | Jen zvuk". The chosen side is filled with the moon colour; on a field, with the type
 * colour at 90 % and the field colour as the label.
 */
@Composable
fun ViewSwitch(soundView: Boolean, choose: (Boolean) -> Unit) {
    val f = LocalOnField.current
    Row(Modifier.fillMaxWidth().wrapContentWidth().clip(RoundedCornerShape(50)).background(if (f != null) FieldGlass else colors.card)
        .selectableGroup().padding(4.dp)) {
        Segment(!soundView, Icons.Filled.Videocam, "Obraz") { choose(false) }
        Segment(soundView, Icons.Filled.GraphicEq, "Jen zvuk") { choose(true) }
    }
}

@Composable
private fun Segment(selected: Boolean, icon: ImageVector, title: String, onClick: () -> Unit) {
    val f = LocalOnField.current
    val bg by animateColorAsState(if (selected) f?.on?.copy(alpha = 0.9f) ?: colors.moon else Color.Transparent, tween(250), label = "segment")
    val ink = if (selected) f?.field ?: Color.Black else f?.on ?: colors.ink
    // A tab for TalkBack, with its selected state. A tap on the chosen side does nothing.
    Row(Modifier.clip(RoundedCornerShape(50)).background(bg)
        .selectable(selected = selected, role = Role.Tab, onClick = { if (!selected) onClick() })
        .padding(horizontal = 18.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(18.dp), tint = ink)
        Spacer(Modifier.width(8.dp))
        Text(title, fontWeight = FontWeight.SemiBold, color = ink)
    }
}

// MARK: The picture view

@Composable
private fun PictureStage(enterPip: () -> Unit, aiming: Boolean, snackbar: SnackbarHostState, animate: Boolean, announce: Boolean,
                         closeAim: () -> Unit) {
    val (w, h) = Monitor.videoSize.collectAsState().value
    val pictureLive by Monitor.pictureLive.collectAsState()
    val state by Monitor.roomState.collectAsState()
    val frame by animateColorAsState(colors.field(state), tween(600), label = "frame")
    Column {
        Box(Modifier.fillMaxWidth().aspectRatio(w.toFloat() / maxOf(h, 1)).clip(RoundedCornerShape(28.dp)).background(Color.Black)) {
            VideoSurface(Modifier.fillMaxSize())
            if (!pictureLive) VideoPlaceholder()
            // A plain if: AnimatedVisibility in a Box inside a Column resolves to the Column's version.
            if (aiming) AimOverlay(snackbar, closeAim)
            if (pictureLive && !App.demo && !aiming) {
                IconButton(onClick = enterPip, Modifier.align(Alignment.BottomEnd).padding(10.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.45f))) {
                    Icon(Icons.Filled.PictureInPictureAlt, "Obraz v obraze", tint = Color.White)
                }
            }
            // The frame light: a 4 dp inner stroke in the state colour, on top of the picture.
            Box(Modifier.matchParentSize().border(4.dp, frame, RoundedCornerShape(28.dp)))
        }
        Spacer(Modifier.height(16.dp))
        Band(animate, announce)
        Spacer(Modifier.height(14.dp))
        PictureWaveform()
    }
}

/** The band on its own: it recomposes once a second, the picture above does not. */
@Composable
private fun Band(animate: Boolean, announce: Boolean) {
    StateBand(roomView(), animate, announce = announce)
}

/** The waveform on its own: it recomposes 10 times a second. */
@Composable
private fun PictureWaveform() {
    val history by Monitor.history.collectAsState()
    val status by Monitor.status.collectAsState()
    Waveform(history, Modifier.height(60.dp), dim = status != SoundStatus.LISTENING && status != SoundStatus.SILENT)
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
        if (c is Connection.Retrying && c.why.startsWith("Kameru teď sleduje")) {
            // The camera allows only a few phones at a time. The monitor tries again by itself.
            Icon(Icons.Filled.Groups, null, tint = colors.warn, modifier = Modifier.size(30.dp))
            Spacer(Modifier.height(8.dp))
            Text(c.why, color = Color.White, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
            Spacer(Modifier.height(8.dp))
            Button(onClick = { Monitor.reconnect("user asked") }) { Text("Zkusit znovu") }
        } else if (c is Connection.Retrying && c.failures >= 2) {
            Icon(Icons.Filled.WifiOff, null, tint = colors.alarm, modifier = Modifier.size(30.dp))
            Spacer(Modifier.height(8.dp))
            Text(if (source == Settings.Source.PHONE) "Telefon u miminka je nedostupný" else "Kamera je nedostupná",
                color = Color.White, fontWeight = FontWeight.SemiBold)
            // The raw reason is in the technical log.
            Text(if (source == Settings.Source.PHONE) "Zkontrolujte, že je telefon u miminka zapnutý a na stejné Wi-Fi."
                 else "Zkontrolujte, že je kamera zapnutá a na stejné Wi-Fi.",
                color = Color.White.copy(alpha = 0.7f), fontSize = 13.sp, textAlign = TextAlign.Center)
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

/**
 * "Natočit": four arrows on the picture, so the parent watches while aiming. The same as on the iPhone:
 * a tap is one step, holding repeats a step every 0.7 s. It closes itself after 20 s with no use.
 */
@Composable
private fun AimOverlay(snackbar: SnackbarHostState, done: () -> Unit) {
    var hint by remember { mutableStateOf(true) }
    var lastUse by remember { mutableLongStateOf(System.currentTimeMillis()) }
    val scope = rememberCoroutineScope()
    val lock = remember { Mutex() }          // One move at a time.
    val currentDone by rememberUpdatedState(done)
    DisposableEffect(Unit) {
        Log.add("aim on")
        onDispose { Log.add("aim off") }
    }
    LaunchedEffect(Unit) {
        delay(2500)
        hint = false
        while (true) {
            delay(2000)
            // Not in the demo: the screenshot must show the arrows.
            if (!App.demo && System.currentTimeMillis() - lastUse > 20_000) {
                Log.add("aim: 20 s with no use")
                currentDone()
                break
            }
        }
    }
    val step: suspend (PtzDirection) -> Unit = { d ->
        lastUse = System.currentTimeMillis()
        hint = false
        if (!App.demo) {
            val ok = lock.withLock { withContext(Dispatchers.IO) { Monitor.move(d) } }
            lastUse = System.currentTimeMillis()
            if (!ok && snackbar.currentSnackbarData == null) scope.launch { snackbar.showSnackbar("Kamera se neotočila.") }
        }
    }
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.22f))) {
        AimArrow(Icons.Filled.KeyboardArrowUp, "Natočit kameru nahoru", Modifier.align(Alignment.TopCenter)) { step(PtzDirection.UP) }
        AimArrow(Icons.Filled.KeyboardArrowDown, "Natočit kameru dolů", Modifier.align(Alignment.BottomCenter)) { step(PtzDirection.DOWN) }
        AimArrow(Icons.AutoMirrored.Filled.KeyboardArrowLeft, "Natočit kameru doleva", Modifier.align(Alignment.CenterStart)) { step(PtzDirection.LEFT) }
        AimArrow(Icons.AutoMirrored.Filled.KeyboardArrowRight, "Natočit kameru doprava", Modifier.align(Alignment.CenterEnd)) { step(PtzDirection.RIGHT) }
        AnimatedVisibility(hint, Modifier.align(Alignment.Center).padding(horizontal = 76.dp), enter = fadeIn(), exit = fadeOut(tween(400))) {
            Text("Klepnutím nebo podržením šipky natočíte kameru",
                Modifier.clip(RoundedCornerShape(50)).background(Color.Black.copy(alpha = 0.55f)).padding(horizontal = 14.dp, vertical = 8.dp),
                color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Medium, textAlign = TextAlign.Center)
        }
        Text("Hotovo",
            Modifier.align(Alignment.TopEnd).padding(12.dp).clip(RoundedCornerShape(50)).background(Color.Black.copy(alpha = 0.45f))
                .clickable { Log.add("aim: Hotovo"); done() }.padding(horizontal = 14.dp, vertical = 8.dp),
            color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** One round arrow: a tap is one step; held, a step every 0.7 s until released. */
@Composable
private fun AimArrow(icon: ImageVector, label: String, modifier: Modifier, step: suspend () -> Unit) {
    var pressed by remember { mutableStateOf(false) }
    val currentStep by rememberUpdatedState(step)
    val scope = rememberCoroutineScope()
    Box(modifier.padding(10.dp).size(54.dp).scale(if (pressed) 0.9f else 1f).clip(CircleShape)
        .background(if (pressed) colors.moon.copy(alpha = 0.6f) else Color.Black.copy(alpha = 0.45f))
        .semantics {
            contentDescription = label
            role = Role.Button
            onClick { scope.launch { currentStep() }; true }
        }
        .pointerInput(Unit) {
            coroutineScope {
                detectTapGestures(onPress = {
                    var held = true
                    pressed = true
                    // Undispatched: a quick tap still makes its one step. A running step always finishes
                    // (it ends with Stop), the loop only checks between the steps.
                    launch(start = CoroutineStart.UNDISPATCHED) {
                        while (true) {
                            val started = System.currentTimeMillis()
                            currentStep()
                            if (!held) break
                            val rest = 700 - (System.currentTimeMillis() - started)
                            if (rest > 0) delay(rest)
                            if (!held) break
                        }
                    }
                    try {
                        tryAwaitRelease()
                    } finally {
                        held = false
                        pressed = false
                    }
                })
            }
        },
        contentAlignment = Alignment.Center) {
        Icon(icon, null, Modifier.size(32.dp), tint = Color.White)
    }
}

// MARK: The sound view (the glance view)

/**
 * The lamp: the field (drawn by the screen, edge to edge), the glyph, the word, the line, the
 * ribbon; under them the glass cards; then the bar. No photo card here: the field gets the space.
 */
@Composable
private fun SoundStage(dim: Boolean, animate: Boolean, announce: Boolean) {
    val on = LocalOnField.current?.on ?: colors.ink
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        GlanceField(dim, animate, announce, Modifier.weight(1f).fillMaxWidth())
        Spacer(Modifier.height(12.dp))
        SoundCards(on)
    }
}

/** The field on its own: it recomposes once a second (the durations), the cards do not. */
@Composable
private fun GlanceField(dim: Boolean, animate: Boolean, announce: Boolean, modifier: Modifier) {
    StateField(roomView(), dim, animate, raiseVolume = { Monitor.raiseVolume() }, modifier, announce = announce)
}

/** The up-close layer: glass (white 12 %) over the field, the waveform and the last sound. */
@Composable
private fun SoundCards(on: Color) {
    val history by Monitor.history.collectAsState()
    val status by Monitor.status.collectAsState()
    val soundNow by Monitor.soundNow.collectAsState()
    val lastSound by Monitor.lastSound.collectAsState()
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { delay(1000); now = System.currentTimeMillis() } }
    val hears = status == SoundStatus.LISTENING || status == SoundStatus.SILENT
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(Color.White.copy(alpha = 0.12f))) {
        // Bars in the type colour: teal bars on a teal field would not show. The height is the level.
        Waveform(history, Modifier.padding(horizontal = 16.dp, vertical = 12.dp).height(36.dp), dim = !hears, tint = on)
        HorizontalDivider(color = on.copy(alpha = 0.15f))
        // The one line about the last sound: there is no hour strip on Android.
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            if (soundNow) {
                Box(Modifier.size(8.dp).clip(CircleShape).background(on))
                Spacer(Modifier.width(8.dp))
            }
            Text(when {
                soundNow -> "Právě se ozývá"
                lastSound != null -> "Poslední zvuk ${ago(lastSound!!, now)}"
                else -> "Zatím ticho"
            }, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = on)
        }
    }
}


/** One photo of the cot, on request: no live picture, no battery cost. Not in Jen zvuk now; kept for later. */
@Composable
private fun PeekCard() {
    var image by remember { mutableStateOf<android.graphics.Bitmap?>(null) }
    var taken by remember { mutableStateOf(0L) }
    var loading by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    fun peek() {
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
            Text("Fotka z postýlky", fontWeight = FontWeight.SemiBold, color = colors.ink)
            val sub = when {
                failed -> "Kamera neodpověděla. Zkuste to znovu."
                loading -> "Fotím…"
                taken > 0 -> "${ago(taken)} · klepnutím obnovíte"
                else -> "Jedna fotka, bez živého obrazu"
            }
            Text(sub, fontSize = 13.sp, color = if (failed) colors.alarm else colors.muted)
        }
    }
}

// MARK: The controls, the warnings

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
                Text(if (volume < 0.01f) "Hlasitost telefonu je vypnutá" else "Hlasitost telefonu je nízká", fontWeight = FontWeight.SemiBold, color = colors.ink)
                Text(if (volume < 0.01f) "Pláč nemusíte slyšet." else "${(volume * 100).toInt()} % · pláč nemusíte slyšet.", fontSize = 13.sp, color = colors.muted)
            }
            Button(onClick = { Monitor.raiseVolume() },
                colors = ButtonDefaults.buttonColors(containerColor = colors.moon, contentColor = Color.Black)) { Text("Zesílit") }
        }
    }
}

@Composable
private fun ControlBar(aiming: Boolean, toggleAim: () -> Unit) {
    val mode by Monitor.mode.collectAsState()
    val ptzReady by Monitor.ptzReady.collectAsState()
    val source by Settings.source.collectAsState()
    val soundView by Settings.soundView.collectAsState()
    // Only for a camera that turns (ONVIF), and only with the picture. The demo shows it for the screenshot.
    val canAim = ((ptzReady && source == Settings.Source.CAMERA) || App.demo) && !soundView
    // On a field: glass buttons with the field's type colour. Muted is the type colour at 90 %
    // with the field colour as the label, like the chosen segment. No brand yellow on a field.
    val f = LocalOnField.current
    val muted = mode == SoundMode.OFF
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.weight(1f)) {
            BarButton(
                title = when (mode) { SoundMode.LIVE -> "Zvuk"; SoundMode.OFF -> "Ztlumeno" },
                icon = when (mode) { SoundMode.LIVE -> Icons.AutoMirrored.Filled.VolumeUp; SoundMode.OFF -> Icons.AutoMirrored.Filled.VolumeOff },
                // Muted is amber: a chosen, safe state. Red is for a fault. Black on amber reads in both light and dark.
                fill = when { f != null && muted -> f.on.copy(alpha = 0.9f); f != null -> FieldGlass; muted -> colors.warn; else -> colors.moon },
                ink = when { f != null && muted -> f.field; f != null -> f.on; else -> Color.Black },
                modifier = Modifier.semantics { stateDescription = if (mode == SoundMode.OFF) "Ztlumeno" else "Živý zvuk" },
                onClick = { Monitor.setMode(if (mode == SoundMode.OFF) SoundMode.LIVE else SoundMode.OFF) },
            )
        }
        if (canAim) {
            Box(Modifier.weight(1f)) {
                BarButton("Natočit", Icons.Filled.OpenWith, if (aiming) colors.moon else colors.card, if (aiming) Color.Black else colors.ink,
                    modifier = Modifier.semantics { stateDescription = if (aiming) "Šipky zobrazené" else "Šipky skryté" },
                    onClick = toggleAim)
            }
        }
        Box(Modifier.weight(1f)) {
            BarButton("Noční", Icons.Filled.Bedtime, if (f != null) FieldGlass else colors.card, f?.on ?: colors.ink,
                onClick = { Monitor.night.value = true; Monitor.reconnect("night mode") })
        }
    }
}

@Composable
private fun BarButton(title: String, icon: ImageVector, fill: Color, ink: Color, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Column(modifier.fillMaxWidth().height(68.dp).clip(RoundedCornerShape(24.dp)).background(fill)
        .clickable(role = Role.Button, onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Icon(icon, null, tint = ink)
        Spacer(Modifier.height(4.dp))
        Text(title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = ink)
    }
}

// MARK: Night mode

/**
 * Almost black, at the lowest brightness: the time, the sound, and the state. A tap shows the
 * controls for 5 s, the next tap hides them. Only "Rozsvítit" ends Night mode, so a missed tap
 * does not light the phone. The explainer shows once, and from the (i) button.
 */
@Composable
fun NightScreen(close: () -> Unit, requestStop: () -> Unit) {
    val history by Monitor.history.collectAsState()
    val status by Monitor.status.collectAsState()
    val soundNow by Monitor.soundNow.collectAsState()
    val volume by Monitor.volume.collectAsState()
    val mode by Monitor.mode.collectAsState()
    val state by Monitor.roomState.collectAsState()
    val view = LocalView.current
    val context = androidx.compose.ui.platform.LocalContext.current
    val window = (view.context as? android.app.Activity)?.window
    DisposableEffect(Unit) {
        // The brightness of this window only: the phone's own setting stays as it is.
        if (window != null && !App.demo) {
            window.attributes = window.attributes.apply { screenBrightness = 0.01f }
        }
        onDispose {
            window?.attributes = window?.attributes?.apply {
                screenBrightness = android.view.WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
            }
        }
    }
    // Pláče lights the lamp a little: 0.01 → 0.08 in 2 s, back to 0.01 30 s after the cry.
    // Not when the parent changed the phone's brightness during this night.
    val crying = state == RoomState.CRY
    val startBrightness = remember { systemBrightness(context) }
    var brightness by remember { mutableFloatStateOf(0.01f) }
    LaunchedEffect(crying) {
        val w = window ?: return@LaunchedEffect
        if (App.demo) return@LaunchedEffect
        suspend fun ramp(to: Float) {
            val from = brightness
            for (i in 1..20) {
                brightness = from + (to - from) * i / 20f
                w.attributes = w.attributes.apply { screenBrightness = brightness }
                delay(100)
            }
        }
        if (crying) {
            if (systemBrightness(context) == startBrightness) ramp(0.08f)
        } else if (brightness > 0.011f) {
            delay(30_000)
            ramp(0.01f)
        }
    }
    var time by remember { mutableStateOf(Date()) }
    LaunchedEffect(Unit) { while (true) { delay(10_000); time = Date() } }
    val battery = remember(time) { batteryNow(context) }
    val prefs = remember { context.getSharedPreferences("settings", Context.MODE_PRIVATE) }
    // Not in the screenshots: they show the screen itself.
    var explain by remember { mutableStateOf(!App.demo && !prefs.getBoolean("nightExplained", false)) }
    // The demo screen "night-controls" shows the controls and keeps them.
    val demoControls = App.demoScreen == "night-controls"
    var controls by remember { mutableStateOf(demoControls) }
    var shown by remember { mutableIntStateOf(0) }
    LaunchedEffect(shown) { if (shown > 0 && !demoControls) { delay(5_000); controls = false } }

    Box(Modifier.fillMaxSize().background(Color.Black).clickable(enabled = !explain, onClickLabel = if (controls) "Skrýt ovládání" else "Zobrazit ovládání") {
        if (controls) controls = false else { controls = true; shown++ }
    }) {
        Column(Modifier.fillMaxSize().alpha(if (explain) 0f else 1f).systemBarsPadding().padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Text(SimpleDateFormat("H:mm", Locale("cs")).format(time), fontSize = 72.sp, fontWeight = FontWeight.Thin, color = DarkPalette.moon.copy(alpha = 0.22f))
            Spacer(Modifier.height(16.dp))
            val low = volume < 0.2f && status == SoundStatus.LISTENING
            NightState(low, muted = mode == SoundMode.OFF, animate = crying && !reduceMotion())
            Spacer(Modifier.height(20.dp))
            Box(Modifier.alpha(if (soundNow) 0.95f else 0.55f)) { Waveform(history, Modifier.height(90.dp).padding(horizontal = 16.dp), dim = !soundNow) }
            Spacer(Modifier.height(40.dp))
            Text(if (controls) "Klepnutím vedle tlačítek je skryjete" else "Klepnutím zobrazíte ovládání", fontSize = 12.sp,
                color = Color.White.copy(alpha = 0.2f), textAlign = TextAlign.Center)
            val (percent, charging) = battery
            if (percent >= 0) {
                Spacer(Modifier.height(10.dp))
                val lowBattery = percent < 20 && !charging
                Text(when { charging -> "$percent % · nabíjí se"; lowBattery -> "$percent % · připojte nabíječku"; else -> "$percent %" },
                    fontSize = 12.sp, color = if (lowBattery) DarkPalette.alarm.copy(alpha = 0.8f) else Color.White.copy(alpha = 0.22f))
            }
        }
        if (!explain) {
            IconButton(onClick = { explain = true }, Modifier.align(Alignment.TopEnd).systemBarsPadding().padding(8.dp)) {
                Icon(Icons.Filled.Info, "Jak funguje noční režim", tint = Color.White.copy(alpha = 0.25f))
            }
        }
        AnimatedVisibility(controls && !explain, Modifier.align(Alignment.BottomCenter), enter = fadeIn(), exit = fadeOut()) {
            Row(Modifier.fillMaxWidth().systemBarsPadding().padding(16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                val muted = mode == SoundMode.OFF
                val glass = Color.White.copy(alpha = 0.12f)
                val ink = Color.White.copy(alpha = 0.85f)
                // Muted is amber, as on the main screen. Stop is red text on dim glass, not a bright pill.
                NightButton(if (muted) "Ztlumeno" else "Zvuk", if (muted) Icons.AutoMirrored.Filled.VolumeOff else Icons.AutoMirrored.Filled.VolumeUp,
                    if (muted) DarkPalette.warn.copy(alpha = 0.85f) else glass, if (muted) Color.Black else ink, Modifier.weight(1f)) {
                    Monitor.setMode(if (muted) SoundMode.LIVE else SoundMode.OFF)
                    shown++                  // The controls stay 5 s more.
                }
                NightButton("Rozsvítit", Icons.Filled.WbSunny, glass, ink, Modifier.weight(1f), onClick = close)
                NightButton("Ukončit hlídání", Icons.Filled.StopCircle, glass, DarkPalette.alarm, Modifier.weight(1f), onClick = requestStop)
            }
        }
        if (explain) {
            NightExplainer(Modifier.align(Alignment.Center)) {
                prefs.edit().putBoolean("nightExplained", true).apply()
                explain = false
            }
        }
    }
}

@Composable
private fun NightButton(title: String, icon: ImageVector, fill: Color, ink: Color, modifier: Modifier, onClick: () -> Unit) {
    // Three in a row: the icon above the word, so the words fit.
    Button(onClick = onClick, modifier.height(64.dp), shape = RoundedCornerShape(18.dp), contentPadding = PaddingValues(horizontal = 6.dp, vertical = 6.dp),
        colors = ButtonDefaults.buttonColors(containerColor = fill, contentColor = ink)) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(icon, null, Modifier.size(20.dp))
            Spacer(Modifier.height(4.dp))
            Text(title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/**
 * The state at night: tint, not paint. Black stays black; the glyph (120 dp) at 45 % and the word
 * (56 sp) at 60 % of the state colour. Pláče: the glyph at 65 % and the disc pulse. Nehlídá: alarm
 * red at 60 %. The line under the word is the old status line.
 */
@Composable
private fun NightState(low: Boolean, muted: Boolean, animate: Boolean) {
    val view = roomView()
    val state = view.state
    val accent = nightAccent(state)
    val glyphAlpha = when (state) { RoomState.CRY -> 0.65f; RoomState.LOST -> 0.6f; RoomState.CONNECTING -> 0.3f; else -> 0.45f }
    val wordAlpha = if (state == RoomState.CONNECTING) 0.4f else 0.6f
    // Silent is muted but hearing: the cry alert still comes.
    val line = when { low -> "Hlasitost telefonu je nízká"; muted -> "Ztlumeno · na pláč upozorní"; else -> view.subline }
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Column(Modifier.fillMaxWidth().clearAndSetSemantics {
            contentDescription = "Stav: ${view.word.lowercase(Locale("cs"))}, $line"
            stateDescription = view.word
        }, horizontalAlignment = Alignment.CenterHorizontally) {
            StateGlyph(state, 120.dp, on = accent.copy(alpha = glyphAlpha), hole = Color.Black, animate = animate,
                alert = DarkPalette.alarm.copy(alpha = 0.6f))
            Spacer(Modifier.height(4.dp))
            FitText(view.word, 56.sp, 32.sp, accent.copy(alpha = wordAlpha), Modifier.fillMaxWidth(), weight = FontWeight.SemiBold)
            Text(line, Modifier.fillMaxWidth(), textAlign = TextAlign.Center, maxLines = 2, color = when {
                state == RoomState.LOST -> DarkPalette.alarm.copy(alpha = 0.6f)
                low -> DarkPalette.warn.copy(alpha = 0.8f)
                else -> Color.White.copy(alpha = if (state == RoomState.CRY || state == RoomState.SOUND) 0.5f else 0.28f)
            })
        }
        StateAnnouncer(state)
    }
}

/** The phone's own brightness setting, to see if the parent changed it during the night. */
private fun systemBrightness(context: Context): Int =
    android.provider.Settings.System.getInt(context.contentResolver, android.provider.Settings.System.SCREEN_BRIGHTNESS, -1)

/** The short explainer of Night mode, the same points as on the iPhone. */
@Composable
private fun NightExplainer(modifier: Modifier, done: () -> Unit) {
    Column(modifier.systemBarsPadding().padding(24.dp).clip(RoundedCornerShape(26.dp)).background(Color(0xFF1C1C1C)).padding(22.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Bedtime, null, tint = DarkPalette.moon)
            Spacer(Modifier.width(10.dp))
            Text("Noční režim", fontSize = 20.sp, fontWeight = FontWeight.SemiBold, color = DarkPalette.moon)
        }
        NightPoint(Icons.Filled.BrightnessLow, "Displej zůstane zapnutý, ale téměř černý a na nejnižším jasu. Telefon se sám nezamkne.")
        NightPoint(Icons.Filled.GraphicEq, "Zvuk i upozornění běží dál. Obraz se zastaví, aby šetřil baterii.")
        NightPoint(Icons.Filled.BatteryChargingFull, "Na celou noc připojte nabíječku. Stav baterie vidíte dole.")
        NightPoint(Icons.Filled.TouchApp, "Klepnutím zobrazíte tlačítka Zvuk, Rozsvítit a Ukončit hlídání. Rozsvítit noční režim ukončí.")
        NightPoint(Icons.Filled.Lock, "Chcete šetřit ještě víc? Telefon klidně zamkněte. Zvuk poběží dál i se zamčenou obrazovkou.")
        Button(onClick = done, Modifier.fillMaxWidth().height(50.dp), shape = RoundedCornerShape(14.dp),
            colors = ButtonDefaults.buttonColors(containerColor = DarkPalette.moon, contentColor = Color.Black)) {
            Text("Rozumím", fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun NightPoint(icon: ImageVector, text: String) {
    Row(verticalAlignment = Alignment.Top) {
        Icon(icon, null, Modifier.size(24.dp), tint = Color.White.copy(alpha = 0.7f))
        Spacer(Modifier.width(12.dp))
        Text(text, fontSize = 15.sp, color = Color.White.copy(alpha = 0.85f))
    }
}

/** The battery in percent (-1 when unknown), and whether it charges. */
private fun batteryNow(context: Context): Pair<Int, Boolean> {
    val i = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
    val level = i?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
    val scale = i?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
    val status = i?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
    val charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
    return (if (level >= 0) level * 100 / maxOf(scale, 1) else -1) to charging
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
