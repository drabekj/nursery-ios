package cz.drabek.chuvicka.ui

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cz.drabek.chuvicka.App
import cz.drabek.chuvicka.Go2rtc
import cz.drabek.chuvicka.Net
import cz.drabek.chuvicka.Settings
import cz.drabek.chuvicka.parent.CameraFinder
import cz.drabek.chuvicka.proto.RtspClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/**
 * "Mimo domov": the one-time setup for the time away from home, as a checklist that ticks itself.
 * The only page that names Tailscale. The monitor uses it by itself once it works.
 */
@Composable
fun RemoteScreen(back: () -> Unit) {
    val context = LocalContext.current
    val source by Settings.source.collectAsState()
    val kind by Settings.cameraKind.collectAsState()
    val ipCamera = source == Settings.Source.CAMERA && kind == Settings.KIND_RTSP
    var here by remember { mutableStateOf(false) }
    var serverOk by remember { mutableStateOf(false) }
    var cameraOk by remember { mutableStateOf(false) }
    var remoteField by remember { mutableStateOf(Settings.remoteHost.value) }
    val babyAddresses by Settings.babyAddresses.collectAsState()
    val babyTailscale = App.demo || babyAddresses.any { RtspClient.isTailscale(it.substringBeforeLast(":")) }

    // The checklist, read again every 2 s.
    LaunchedEffect(ipCamera) {
        var n = 0
        while (true) {
            if (App.demo) { here = true; serverOk = true; cameraOk = true }
            else {
                here = withContext(Dispatchers.IO) { Net.hasTailscale() }
                if (ipCamera) {
                    // The camera's home address answers with Tailscale on, away from home: the route works.
                    // At home it answers anyway, so it counts only on another network.
                    val host = hostOf(Settings.rtspUrl.value.trim())
                    cameraOk = here && host.isNotEmpty() && withContext(Dispatchers.IO) {
                        CameraFinder.homeNetwork()?.second != host.substringBeforeLast('.') && RtspClient.canConnect(host, 554)
                    }
                } else if (Settings.source.value == Settings.Source.CAMERA) {
                    val h = Settings.remoteHost.value.trim()
                    serverOk = h.isNotEmpty() && withContext(Dispatchers.IO) { RtspClient.canConnect(h, Go2rtc.RTSP_PORT) }
                } else if (n % 5 == 0 && !Settings.babyAddresses.value.any { RtspClient.isTailscale(it.substringBeforeLast(":")) }) {
                    // The phone at the baby tells its new addresses when we connect: ask it now and then.
                    withContext(Dispatchers.IO) { refreshBabyAddresses(context) }
                }
            }
            n++
            delay(2000)
        }
    }

    Page("Mimo domov", back) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
            Text("Chcete se dívat i mimo domov, třeba z práce? Stačí bezplatná aplikace Tailscale, která vaše telefony bezpečně propojí. Nastavíte ji jednou.",
                fontSize = 17.sp, lineHeight = 24.sp, color = colors.ink)
            Spacer(Modifier.height(16.dp))
            if (ipCamera) {
                CheckItem(here, "Tailscale v tomto telefonu", if (here) null else "Nainstalujte Tailscale a přihlaste se.") {
                    if (!here) OutlinedButton(onClick = { openTailscaleStore(context) }, Modifier.heightIn(min = 48.dp)) { Text("Stáhnout Tailscale", color = colors.accent) }
                }
                Spacer(Modifier.height(12.dp))
                CheckItem(cameraOk, "Domácí síť přes Tailscale",
                    if (cameraOk) null else "Pro pokročilé: na počítači nebo routeru doma zapněte v Tailscale sdílení domácí sítě (subnet route) pro adresu kamery. Pak Chůvička mimo domov použije stejnou adresu kamery jako doma. Ověří se samo, až budete mimo domov.")
                Spacer(Modifier.height(12.dp))
                RemoteNote("Tailscale vytvoří soukromou šifrovanou síť jen pro vaše zařízení. Obraz nejde přes žádný cizí server. Doma Chůvička funguje i bez něj.")
            } else {
                CheckItem(here, "Tailscale v tomto telefonu", if (here) null else "Nainstalujte Tailscale a přihlaste se.") {
                    if (!here) OutlinedButton(onClick = { openTailscaleStore(context) }, Modifier.heightIn(min = 48.dp)) { Text("Stáhnout Tailscale", color = colors.accent) }
                }
                Spacer(Modifier.height(12.dp))
                if (source == Settings.Source.PHONE) {
                    CheckItem(babyTailscale, "Tailscale v telefonu u miminka",
                        if (babyTailscale) null else "Nainstalujte Tailscale i na telefon u miminka, přihlaste se stejným účtem a jednou se k němu připojte doma.")
                } else {
                    CheckItem(serverOk, "Server přes Tailscale", if (serverOk) null else "Server musí mít Tailscale zapnutý.") {
                        OutlinedTextField(remoteField, { remoteField = it; Settings.set(Settings.remoteHost, "remoteHost", it.trim()) },
                            Modifier.fillMaxWidth().padding(top = 8.dp), label = { Text("Adresa serveru v Tailscale") },
                            supportingText = { Text("název zařízení v Tailscale nebo adresa 100.x.y.z") }, singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
                    }
                }
                Spacer(Modifier.height(12.dp))
                Text("Každý bod se zaškrtne sám, jakmile je hotový. Pak Chůvička mimo domov použije Tailscale sama.",
                    fontSize = 15.sp, color = colors.muted)
                Spacer(Modifier.height(12.dp))
                RemoteNote("Tailscale vytvoří soukromou šifrovanou síť jen pro vaše zařízení. Obraz nejde přes žádný cizí server. Doma Chůvička funguje i bez něj.")
            }
        }
    }
}

@Composable
private fun CheckItem(ok: Boolean, title: String, hint: String?, extra: @Composable ColumnScope.() -> Unit = {}) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(colors.card).padding(16.dp), verticalAlignment = Alignment.Top) {
        Icon(if (ok) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked, if (ok) "Hotovo" else "Zatím ne",
            Modifier.size(28.dp), tint = if (ok) colors.calm else colors.neutral)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = colors.ink)
            if (hint != null) Text(hint, fontSize = 15.sp, lineHeight = 21.sp, color = colors.muted)
            extra()
        }
    }
}

@Composable
private fun RemoteNote(text: String) {
    Text(text, Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(colors.card).padding(14.dp),
        fontSize = 15.sp, lineHeight = 21.sp, color = colors.muted)
}

private fun openTailscaleStore(context: Context) {
    val market = Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=com.tailscale.ipn")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    try {
        context.startActivity(market)
    } catch (e: ActivityNotFoundException) {
        try {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=com.tailscale.ipn"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: ActivityNotFoundException) {}
    }
}

/** A short DESCRIBE to the phone at the baby: it reports its addresses, maybe a new Tailscale one. */
private fun refreshBabyAddresses(context: Context) {
    try {
        val c = testClient(context)
        try {
            c.start()
            if (c.serverAddresses.isNotEmpty()) Settings.setBabyAddresses(c.serverAddresses)
        } finally {
            c.close()
        }
    } catch (_: Exception) {
    }
}
