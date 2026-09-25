package cz.drabek.chuvicka.ui

import android.content.Intent
import android.content.IntentFilter
import android.graphics.BitmapFactory
import android.os.BatteryManager
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BatteryChargingFull
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.ScreenLockPortrait
import androidx.compose.material.icons.filled.StayCurrentLandscape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cz.drabek.chuvicka.App
import cz.drabek.chuvicka.R
import cz.drabek.chuvicka.Settings
import cz.drabek.chuvicka.baby.BabyState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** The screen of the phone at the baby: the choices before the start, a dark screen while it sends. */
@Composable
fun BabyScreen(start: () -> Unit, stop: () -> Unit, becomeParent: () -> Unit, openWizard: () -> Unit) {
    val running by BabyState.running.collectAsState()
    if (running) BabySending(stop) else BabySetup(start, becomeParent, openWizard)
}

@Composable
private fun BabySetup(start: () -> Unit, becomeParent: () -> Unit, openWizard: () -> Unit) {
    val code by Settings.unitCode.collectAsState()
    val name by Settings.unitName.collectAsState()
    val video by Settings.unitVideo.collectAsState()
    val front by Settings.unitFront.collectAsState()
    val error by BabyState.error.collectAsState()
    var confirmParent by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().background(colors.sky).systemBarsPadding().verticalScroll(rememberScrollState()).padding(20.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Icon(Icons.Filled.PhoneAndroid, null, Modifier.size(48.dp).padding(top = 8.dp), tint = colors.accent)
        Text("Telefon u miminka", fontSize = 32.sp, fontWeight = FontWeight.SemiBold, color = colors.ink)
        Text("Tento telefon vysílá obraz a zvuk od postýlky do telefonů rodičů, iPhonů i Androidů.",
            color = colors.muted, textAlign = TextAlign.Center)

        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(colors.card).padding(18.dp),
            horizontalAlignment = Alignment.CenterHorizontally) {
            PairQr()
            Spacer(Modifier.height(16.dp))
            Text("Nebo zadejte párovací kód", fontWeight = FontWeight.SemiBold, color = colors.muted)
            Text(spaced(code), fontSize = 44.sp, fontWeight = FontWeight.SemiBold, color = colors.ink)
            Text("Na telefonu rodiče: Nastavení → Zdroj → Telefon u miminka.", fontSize = 12.sp, color = colors.muted, textAlign = TextAlign.Center)
            TextButton(onClick = { Settings.set(Settings.unitCode, "unitCode", Settings.newCode()) }) { Text("Nový kód") }
        }

        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(colors.card).padding(vertical = 6.dp)) {
            OutlinedTextField(name, { Settings.set(Settings.unitName, "unitName", it.take(40)) }, Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                label = { Text("Název") }, singleLine = true)
            Row(Modifier.padding(16.dp)) {
                val segment = SegmentedButtonDefaults.colors(activeContainerColor = colors.moon, activeContentColor = Color.Black,
                    inactiveContainerColor = colors.card, inactiveContentColor = colors.ink)
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    SegmentedButton(video, { Settings.set(Settings.unitVideo, "unitVideo", true) }, SegmentedButtonDefaults.itemShape(0, 2), colors = segment) { Text("Obraz i zvuk") }
                    SegmentedButton(!video, { Settings.set(Settings.unitVideo, "unitVideo", false) }, SegmentedButtonDefaults.itemShape(1, 2), colors = segment) { Text("Jen zvuk") }
                }
            }
            if (video) Choice("Kamera", listOf(false to "Zadní", true to "Přední"), front) { Settings.set(Settings.unitFront, "unitFront", it) }
        }

        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Tip(Icons.Filled.BatteryChargingFull, "Připojte nabíječku. Vysílání obrazu přes noc spotřebuje hodně baterie a telefon se trochu zahřeje.")
            Tip(Icons.Filled.StayCurrentLandscape, "Položte telefon naležato, 1–2 metry od postýlky, nikdy ne do ní.")
            Tip(Icons.Filled.ScreenLockPortrait, "Displej klidně zhasněte. Obraz i zvuk se vysílají dál.")
        }
        error?.let { Text(it, color = colors.alarm) }
        Button(onClick = start, Modifier.fillMaxWidth().height(56.dp), shape = RoundedCornerShape(20.dp),
            colors = ButtonDefaults.buttonColors(containerColor = colors.moon, contentColor = Color.Black)) {
            Text("Začít vysílat", fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
        }
        TextButton(onClick = { confirmParent = true }) { Text("Tento telefon je rodičovský") }
        TextButton(onClick = openWizard) { Text("Průvodce nastavením") }
    }
    if (confirmParent) AlertDialog(
        onDismissRequest = { confirmParent = false },
        title = { Text("Používat tento telefon jako rodičovský?") },
        text = { Text("Chůvička pak na tomto telefonu ukazuje obraz a zvuk z pokojíčku.") },
        confirmButton = { TextButton(onClick = { confirmParent = false; becomeParent() }) { Text("Ano, bude hlídat") } },
        dismissButton = { TextButton(onClick = { confirmParent = false }) { Text("Zrušit") } },
    )
}

@Composable
private fun Tip(icon: ImageVector, text: String) {
    Row(verticalAlignment = Alignment.Top) {
        Icon(icon, null, tint = colors.accent)
        Spacer(Modifier.width(12.dp))
        Text(text, color = colors.ink)
    }
}

private fun spaced(code: String) = if (code.length == 6) code.take(3) + " " + code.takeLast(3) else code

/** Dark, so it gives no light in the nursery. A tap shows the preview and the controls for 20 s. */
@Composable
private fun BabySending(stop: () -> Unit) {
    val parents by BabyState.parents.collectAsState()
    val history by BabyState.history.collectAsState()
    val name by Settings.unitName.collectAsState()
    val code by Settings.unitCode.collectAsState()
    val video by Settings.unitVideo.collectAsState()
    var awake by remember { mutableStateOf(true) }
    var wakeCount by remember { mutableIntStateOf(0) }
    var preview by remember { mutableStateOf<android.graphics.Bitmap?>(null) }
    val view = LocalView.current
    val context = LocalContext.current

    DisposableEffect(awake) {
        view.keepScreenOn = true
        val window = (view.context as? android.app.Activity)?.window
        if (!awake && !App.demo) window?.attributes = window?.attributes?.apply { screenBrightness = 0.01f }
        onDispose {
            window?.attributes = window?.attributes?.apply { screenBrightness = android.view.WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE }
        }
    }
    DisposableEffect(Unit) { onDispose { view.keepScreenOn = false } }
    LaunchedEffect(wakeCount) { awake = true; delay(20_000); awake = false }
    LaunchedEffect(awake) {
        while (awake && video && !App.demo) {
            val jpeg = withContext(Dispatchers.IO) { BabyState.capture?.frame() }
            jpeg?.let { preview = BitmapFactory.decodeByteArray(it, 0, it.size) }
            delay(1000)
        }
    }
    val battery = remember(history) {
        val i = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = i?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = i?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        val status = i?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
        (if (level >= 0) level * 100 / scale else -1) to charging
    }
    val statusText = when (parents) {
        0 -> "$name · čeká na telefon rodiče"
        1 -> "$name · vysílá do 1 telefonu"
        else -> "$name · vysílá do $parents telefonů"
    }
    var time by remember { mutableStateOf(Date()) }
    LaunchedEffect(Unit) { while (true) { delay(10_000); time = Date() } }

    Box(Modifier.fillMaxSize().background(Color.Black).clickable { wakeCount++ }) {
        Column(Modifier.fillMaxSize().systemBarsPadding().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center) {
            if (!awake) {
                Text(SimpleDateFormat("H:mm", Locale("cs")).format(time), fontSize = 64.sp, fontWeight = FontWeight.Thin, color = DarkPalette.moon.copy(alpha = 0.2f))
                Spacer(Modifier.height(24.dp))
                Waveform(history, Modifier.height(70.dp).padding(horizontal = 16.dp), dim = true)
                Spacer(Modifier.height(24.dp))
                Text(statusText, color = Color.White.copy(alpha = 0.3f), textAlign = TextAlign.Center)
                Spacer(Modifier.height(48.dp))
                Text("Klepnutím zobrazíte ovládání", fontSize = 12.sp, color = Color.White.copy(alpha = 0.16f))
            }
        }
        AnimatedVisibility(awake, enter = fadeIn(), exit = fadeOut()) {
            Column(Modifier.fillMaxSize().systemBarsPadding().verticalScroll(rememberScrollState()).padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically)) {
                if (video) {
                    Box(Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(RoundedCornerShape(20.dp)).background(Color.White.copy(alpha = 0.06f)),
                        contentAlignment = Alignment.Center) {
                        when {
                            App.demo -> Image(painterResource(R.drawable.demo_frame), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                            preview != null -> Image(preview!!.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
                            else -> CircularProgressIndicator(color = Color.White)
                        }
                    }
                    Text("Náhled. Namiřte telefon na postýlku.", fontSize = 12.sp, color = Color.White.copy(alpha = 0.6f))
                }
                Text(statusText, fontWeight = FontWeight.SemiBold, color = if (parents > 0) DarkPalette.calm else Color.White.copy(alpha = 0.7f))
                // The QR code, also for a second parent's phone.
                PairQr(size = if (video) 150.dp else 200.dp, labelColor = Color.White.copy(alpha = 0.7f))
                Text("Kód  ${spaced(code)}", fontWeight = FontWeight.SemiBold, color = Color.White.copy(alpha = 0.85f))
                Button(onClick = stop, Modifier.widthIn(max = 320.dp).fillMaxWidth().height(50.dp), shape = RoundedCornerShape(16.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = DarkPalette.alarm.copy(alpha = 0.85f), contentColor = Color.White)) {
                    Text("Ukončit vysílání", fontWeight = FontWeight.SemiBold)
                }
                Text("Displej můžete zhasnout tlačítkem. Vysílání poběží dál.", fontSize = 12.sp, color = Color.White.copy(alpha = 0.4f), textAlign = TextAlign.Center)
            }
        }
        val (percent, charging) = battery
        if (percent >= 0) Text(if (charging) "$percent % · nabíjí se" else "$percent % · připojte nabíječku",
            Modifier.align(Alignment.BottomCenter).systemBarsPadding().padding(bottom = 16.dp), fontSize = 12.sp,
            color = if (charging) Color.White.copy(alpha = 0.22f) else DarkPalette.alarm.copy(alpha = 0.8f))
    }
}
