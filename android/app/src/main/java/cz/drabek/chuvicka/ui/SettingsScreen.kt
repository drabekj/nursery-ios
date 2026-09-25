package cz.drabek.chuvicka.ui

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cz.drabek.chuvicka.Log
import cz.drabek.chuvicka.PairLink
import cz.drabek.chuvicka.Settings
import cz.drabek.chuvicka.parent.BabyFinder
import cz.drabek.chuvicka.parent.Monitor

@Composable
fun SettingsScreen(back: () -> Unit, openPairing: () -> Unit, openLog: () -> Unit, becomeBaby: () -> Unit, openWizard: () -> Unit) {
    val source by Settings.source.collectAsState()
    val cameraKind by Settings.cameraKind.collectAsState()
    val rtspBrand by Settings.rtspBrand.collectAsState()
    val rtspUrl by Settings.rtspUrl.collectAsState()
    val host by Settings.host.collectAsState()
    val babyName by Settings.babyName.collectAsState()
    val loudness by Settings.loudness.collectAsState()
    val appearance by Settings.appearance.collectAsState()
    val alertOnLoss by Settings.alertOnLoss.collectAsState()
    val remoteHost by Settings.remoteHost.collectAsState()
    val babyAddresses by Settings.babyAddresses.collectAsState()
    val viaTailscale by Monitor.viaTailscale.collectAsState()
    var hostField by remember { mutableStateOf(host) }
    var remoteField by remember { mutableStateOf(remoteHost) }
    var confirmBaby by remember { mutableStateOf(false) }

    Page("Nastavení", back) {
        val babyTailscale = babyAddresses.firstOrNull { cz.drabek.chuvicka.proto.RtspClient.isTailscale(it.substringBeforeLast(":")) }
        val ipCamera = source == Settings.Source.CAMERA && cameraKind == Settings.KIND_RTSP
        Section("Zdroj", footer = if (ipCamera)
            "IP kamera v domácí síti. Mimo domov ji Chůvička neukáže: do kamery nejde nainstalovat Tailscale. Na dálku pomůže druhý telefon u postýlky nebo server go2rtc."
        else if (source == Settings.Source.CAMERA)
            "Počítač, na kterém běží go2rtc. Doma se Chůvička připojí na jeho adresu v síti. Mimo domov použije adresu přes Tailscale, když je v telefonu Tailscale zapnutý."
        else "Druhý telefon s Chůvičkou u postýlky, iPhone nebo Android, posílá obraz a zvuk přímo do tohoto telefonu. " +
            (if (babyTailscale != null) "Mimo domov přes Tailscale: $babyTailscale."
             else "Pro hlídání mimo domov nainstalujte Tailscale i na telefon u miminka a jednou se k němu připojte doma.")) {
            Choice("Obraz a zvuk z", listOf(Settings.Source.CAMERA to "Kamera v pokojíčku", Settings.Source.PHONE to "Telefon u miminka"), source) {
                Settings.set(Settings.source, "source", it); Monitor.reconnect("source changed")
            }
            if (ipCamera) {
                Row(Modifier.fillMaxWidth().clickable(onClick = openWizard).padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("IP kamera ${rtspBrand.title}", color = colors.ink)
                        Text(rtspUrl, fontSize = 13.sp, color = colors.muted)
                    }
                    Text("Změnit", color = colors.accent)
                }
            } else if (source == Settings.Source.CAMERA) {
                OutlinedTextField(hostField, { hostField = it }, Modifier.fillMaxWidth().padding(16.dp), label = { Text("Adresa serveru") },
                    singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
                OutlinedTextField(remoteField, { remoteField = it }, Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 16.dp),
                    label = { Text("Mimo domov (Tailscale)") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
                if (hostField.trim() != host || remoteField.trim() != remoteHost) {
                    TextButton(onClick = {
                        Settings.set(Settings.host, "host", hostField.trim())
                        Settings.set(Settings.remoteHost, "remoteHost", remoteField.trim())
                        Monitor.reconnect("new server address")
                    }, Modifier.padding(horizontal = 8.dp)) { Text("Použít tyto adresy") }
                }
            } else {
                Row(Modifier.fillMaxWidth().clickable(onClick = openPairing).padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Telefon u miminka", Modifier.weight(1f), color = colors.ink)
                    Text(babyName.ifEmpty { "Nespárováno" }, color = colors.accent)
                }
            }
        }
        Section("Stav") {
            Row(Modifier.fillMaxWidth().padding(16.dp)) {
                Text("Cesta", Modifier.weight(1f), color = colors.ink)
                Text(if (viaTailscale) "Přes Tailscale" else "Doma", color = colors.muted)
            }
        }
        Section("Zvuk", footer = "Zesílená hlasitost přidá 12 dB, maximální 20 dB. Podržením tlačítka Zvuk zvolíte tichý režim: Chůvička nic nehraje, ale při zvuku upozorní.") {
            Choice("Hlasitost", Settings.Loudness.entries.map { it to it.title }, loudness) {
                Settings.set(Settings.loudness, "loudness", it); Monitor.setGain(it.decibels)
            }
        }
        Section("Upozornění") {
            Switchy("Upozornit na výpadek zvuku", alertOnLoss) { Settings.set(Settings.alertOnLoss, "alertOnLoss", it) }
        }
        Section("Displej") {
            Choice("Vzhled", Settings.Appearance.entries.map { it to it.title }, appearance) { Settings.set(Settings.appearance, "appearance", it) }
        }
        Section("Průvodce", footer = "Provede vás nastavením krok za krokem, jako při prvním spuštění.") {
            Row(Modifier.fillMaxWidth().clickable(onClick = openWizard).padding(16.dp)) { Text("Průvodce nastavením", color = colors.ink) }
        }
        Section("Tento telefon", footer = "Tento telefon pak nehlídá, ale vysílá: jeho kamera a mikrofon budou u postýlky.") {
            TextButton(onClick = { confirmBaby = true }, Modifier.padding(horizontal = 8.dp)) { Text("Použít jako telefon u miminka") }
        }
        Section("Diagnostika") {
            Row(Modifier.fillMaxWidth().clickable(onClick = openLog).padding(16.dp)) { Text("Technický záznam", color = colors.ink) }
        }
        Text("Doma jde obraz v domácí síti, mimo domov šifrovaně přes váš Tailscale. Obraz ani zvuk nikdy nejdou přes cizí server.",
            Modifier.padding(horizontal = 20.dp, vertical = 8.dp), fontSize = 13.sp, color = colors.muted)
    }
    if (confirmBaby) AlertDialog(
        onDismissRequest = { confirmBaby = false },
        title = { Text("Používat tento telefon u miminka?") },
        text = { Text("Hlídání na tomto telefonu se vypne. Zpět ho přepnete na obrazovce telefonu u miminka.") },
        confirmButton = { TextButton(onClick = { confirmBaby = false; becomeBaby() }) { Text("Ano, bude vysílat") } },
        dismissButton = { TextButton(onClick = { confirmBaby = false }) { Text("Zrušit") } },
    )
}

/** On the parent: find the phone at the baby with mDNS, and pair with its code. */
@Composable
fun PairingScreen(back: () -> Unit, openScanner: () -> Unit) {
    val context = LocalContext.current
    val finder = remember { BabyFinder(context) }
    DisposableEffect(Unit) { finder.start(); onDispose { finder.stop() } }
    val names by finder.names.collectAsState()
    val babyName by Settings.babyName.collectAsState()
    var picking by remember { mutableStateOf<String?>(null) }

    Page("Telefon u miminka", back) {
        Button(onClick = openScanner, Modifier.padding(horizontal = 16.dp, vertical = 8.dp).fillMaxWidth().height(56.dp), shape = RoundedCornerShape(20.dp),
            colors = ButtonDefaults.buttonColors(containerColor = colors.moon, contentColor = Color.Black)) {
            Icon(Icons.Filled.QrCodeScanner, null)
            Spacer(Modifier.width(10.dp))
            Text("Naskenovat QR kód", fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
        }
        if (babyName.isNotEmpty()) Section("Spárováno") {
            Row(Modifier.fillMaxWidth().padding(16.dp)) {
                Text(babyName, Modifier.weight(1f), color = colors.ink)
                TextButton(onClick = { Settings.set(Settings.babyName, "babyName", ""); Settings.set(Settings.babyCode, "babyCode", "") }) {
                    Text("Zrušit spárování", color = colors.alarm)
                }
            }
        }
        Section("Telefony u miminka v okolí") {
            if (names.isEmpty()) Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(12.dp))
                Text("Hledám telefon u miminka…", color = colors.muted)
            }
            names.forEach { name ->
                Row(Modifier.fillMaxWidth().clickable { picking = name }.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.PhoneAndroid, null, tint = colors.accent)
                    Spacer(Modifier.width(12.dp))
                    Text(name, Modifier.weight(1f), color = colors.ink)
                    if (name == babyName) Icon(Icons.Filled.Check, null, tint = colors.accent)
                }
            }
        }
        Section("Jak na to") {
            Step(1, "Na druhém telefonu (iPhonu nebo Androidu) otevřete Chůvičku → Nastavení → Použít jako telefon u miminka.")
            Step(2, "Položte ho k postýlce, 1–2 metry od miminka, a připojte nabíječku.")
            Step(3, "Naskenujte jeho QR kód, nebo tady klepněte na jeho název a zadejte šestimístný kód, který ukazuje.")
        }
    }
    picking?.let { name -> PairCodeDialog(name, dismiss = { picking = null }, paired = { picking = null; Monitor.reconnect("paired") }) }
}

/** The 6-digit code of the phone at the baby, by hand. It saves the pairing. */
@Composable
fun PairCodeDialog(name: String, dismiss: () -> Unit, paired: () -> Unit) {
    var code by remember(name) { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text("Párovací kód") },
        text = {
            Column {
                Text("Zadejte kód, který ukazuje telefon „$name“.")
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(code, { v -> code = v.filter(Char::isDigit).take(6) }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword), label = { Text("6 číslic") })
            }
        },
        confirmButton = {
            TextButton(enabled = code.length == 6, onClick = {
                // Another phone: the addresses of the old one are no use.
                if (name != Settings.babyName.value) Settings.setBabyAddresses(emptyList())
                Settings.set(Settings.babyCode, "babyCode", code)
                Settings.set(Settings.babyName, "babyName", name)
                Settings.set(Settings.source, "source", Settings.Source.PHONE)
                paired()
            }) { Text("Spárovat") }
        },
        dismissButton = { TextButton(onClick = dismiss) { Text("Zrušit") } },
    )
}

/** The QR scanner as a page of the settings. */
@Composable
fun ScannerPage(back: () -> Unit, paired: () -> Unit) {
    Page("Naskenovat QR kód", back) {
        QrScanner(found = { link -> PairLink.apply(link); paired() }, modifier = Modifier.padding(16.dp))
    }
}

@Composable
fun LogScreen(back: () -> Unit) {
    val lines by Log.lines.collectAsState()
    val context = LocalContext.current
    Column(Modifier.fillMaxSize().background(colors.sky).systemBarsPadding()) {
        Header("Technický záznam", back) {
            IconButton(onClick = {
                val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, lines.joinToString("\n"))
                context.startActivity(Intent.createChooser(send, "Sdílet záznam"))
            }) { Icon(Icons.Filled.Share, "Sdílet", tint = colors.accent) }
        }
        LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
            items(lines.reversed()) { Text(it, fontSize = 13.sp, color = colors.ink, modifier = Modifier.padding(vertical = 3.dp)) }
        }
    }
}

// MARK: The parts of a settings page

@Composable
fun Page(title: String, back: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize().background(colors.sky).systemBarsPadding()) {
        Header(title, back)
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 24.dp), content = content)
    }
}

@Composable
private fun Header(title: String, back: () -> Unit, actions: @Composable () -> Unit = {}) {
    Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Zpět", tint = colors.accent) }
        Text(title, Modifier.weight(1f), fontSize = 20.sp, fontWeight = FontWeight.SemiBold, color = colors.ink)
        actions()
    }
}

@Composable
fun Section(title: String, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Text(title, Modifier.padding(start = 20.dp, top = 18.dp, bottom = 6.dp), fontWeight = FontWeight.SemiBold, color = colors.muted)
    Column(Modifier.padding(horizontal = 16.dp).fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(colors.card), content = content)
    if (footer != null) Text(footer, Modifier.padding(horizontal = 20.dp, vertical = 6.dp), fontSize = 13.sp, color = colors.muted)
}

@Composable
fun <T> Choice(label: String, options: List<Pair<T, String>>, selected: T, choose: (T) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Row(Modifier.fillMaxWidth().clickable { open = true }.padding(16.dp)) {
            Text(label, Modifier.weight(1f), color = colors.ink)
            Text(options.firstOrNull { it.first == selected }?.second ?: "", color = colors.accent)
        }
        DropdownMenu(open, onDismissRequest = { open = false }, Modifier.background(colors.card)) {
            options.forEach { (value, title) -> DropdownMenuItem(text = { Text(title) }, onClick = { choose(value); open = false }) }
        }
    }
}

@Composable
fun Switchy(label: String, on: Boolean, set: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f), color = colors.ink)
        Switch(on, set, colors = SwitchDefaults.colors(checkedTrackColor = colors.accent))
    }
}

@Composable
private fun Step(n: Int, text: String) {
    Row(Modifier.padding(16.dp), verticalAlignment = Alignment.Top) {
        Box(Modifier.size(24.dp).clip(CircleShape).background(colors.moon), contentAlignment = Alignment.Center) {
            Text("$n", fontWeight = FontWeight.Bold, color = Color.Black, fontSize = 13.sp)
        }
        Spacer(Modifier.width(12.dp))
        Text(text, color = colors.ink)
    }
}
