package cz.drabek.chuvicka.ui

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cz.drabek.chuvicka.App
import cz.drabek.chuvicka.Log
import cz.drabek.chuvicka.Settings
import cz.drabek.chuvicka.parent.BabyFinder
import cz.drabek.chuvicka.parent.StreamDiscovery
import cz.drabek.chuvicka.proto.H264Depacketizer
import cz.drabek.chuvicka.proto.RtpPacket
import cz.drabek.chuvicka.proto.RtspClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicBoolean

enum class TestCheck { WAIT, OK, FAIL }

/** The result of a connection test, row by row. */
data class TestState(
    val connect: TestCheck = TestCheck.WAIT,
    val video: TestCheck = TestCheck.WAIT,
    val audio: TestCheck = TestCheck.WAIT,
    val videoWhy: String? = null,
    val audioWhy: String? = null,
    val error: String? = null,
) {
    val done get() = connect == TestCheck.FAIL || (video != TestCheck.WAIT && audio != TestCheck.WAIT)
    val ok get() = connect == TestCheck.OK && (video == TestCheck.OK || audio == TestCheck.OK)
}

/**
 * A live test of the chosen source: connect, then up to 4 s of the stream, counting frames of
 * the picture and packets of the sound. Stop the monitor first: a camera may take one client only.
 */
@Composable
fun ConnectionTest(onResult: (TestState) -> Unit = {}) {
    val context = LocalContext.current
    var attempt by remember { mutableIntStateOf(0) }
    var state by remember { mutableStateOf(TestState()) }
    var slow by remember { mutableStateOf(false) }
    val report by rememberUpdatedState(onResult)
    val phone = Settings.source.collectAsState().value == Settings.Source.PHONE

    LaunchedEffect(attempt) {
        state = TestState()
        slow = false
        if (App.demo) {
            delay(500); state = state.copy(connect = TestCheck.OK)
            delay(500); state = state.copy(video = TestCheck.OK, audio = TestCheck.OK)
            report(state); return@LaunchedEffect
        }
        state = withContext(Dispatchers.IO) { connectionTest(context) { partial -> state = partial } }
        report(state)
    }
    LaunchedEffect(attempt) { delay(10_000); slow = true }

    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(colors.card).padding(vertical = 6.dp)) {
        CheckRow(state.connect, if (phone) "Spojení s telefonem u miminka" else "Spojení s kamerou",
            if (state.connect == TestCheck.FAIL) state.error else null)
        CheckRow(if (state.connect == TestCheck.FAIL) TestCheck.FAIL else state.video, "Obraz", state.videoWhy)
        CheckRow(if (state.connect == TestCheck.FAIL) TestCheck.FAIL else state.audio, "Zvuk", state.audioWhy)
    }
    if (!state.done && slow) {
        Spacer(Modifier.height(10.dp))
        Text(if (phone) "Trvá to dlouho? Zkontrolujte, že na druhém telefonu běží vysílání a oba telefony jsou na stejné Wi-Fi."
             else "Trvá to dlouho? Zkontrolujte, že je kamera zapnutá a ve stejné Wi-Fi jako tento telefon.",
            fontSize = 14.sp, color = colors.muted)
    }
    if (state.done && (!state.ok || state.video == TestCheck.FAIL || state.audio == TestCheck.FAIL)) {
        TextButton(onClick = { attempt++ }) { Text("Zkusit znovu", fontSize = 16.sp) }
    }
}

@Composable
private fun CheckRow(check: TestCheck, title: String, why: String?) {
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(28.dp), contentAlignment = Alignment.Center) {
            when (check) {
                TestCheck.WAIT -> CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp, color = colors.accent)
                TestCheck.OK -> Icon(Icons.Filled.CheckCircle, "V pořádku", Modifier.size(28.dp), tint = colors.calm)
                TestCheck.FAIL -> Icon(Icons.Filled.Cancel, "Nefunguje", Modifier.size(28.dp), tint = colors.alarm)
            }
        }
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = colors.ink)
            if (why != null && check == TestCheck.FAIL) Text(why, fontSize = 14.sp, color = colors.muted)
        }
    }
}

/** The client for the chosen source, as the monitor makes it, but at home (no Tailscale switch). */
fun testClient(context: Context): RtspClient {
    if (Settings.source.value == Settings.Source.CAMERA) {
        val url = if (Settings.cameraKind.value == Settings.KIND_RTSP) Settings.cameraUrl(small = false)
                  else Settings.go2rtcUrl(Settings.host.value.trim(), small = false)
        return RtspClient.forUrl(url)
    }
    val name = Settings.babyName.value
    val code = Settings.babyCode.value
    if (name.isEmpty() || code.isEmpty()) throw RtspClient.Failure("Telefon u miminka ještě není spárovaný.")
    // The saved addresses first (from the QR code): quicker than the search in the Wi-Fi.
    val target = Settings.babyAddresses.value.firstNotNullOfOrNull { a ->
        val host = a.substringBeforeLast(":")
        val port = a.substringAfterLast(":").toIntOrNull() ?: return@firstNotNullOfOrNull null
        if (RtspClient.canConnect(host, port)) host to port else null
    } ?: BabyFinder.resolve(context, name)
      ?: throw RtspClient.Failure("Telefon „$name“ se nenašel. Běží na něm vysílání a je na stejné Wi-Fi?")
    return RtspClient("rtsp://chuvicka/$code", target.first, target.second)
}

/** It blocks for up to about 10 s, more while it learns the go2rtc streams. [partial] gets the state after the connection. */
fun connectionTest(context: Context, partial: (TestState) -> Unit): TestState {
    val phone = Settings.source.value == Settings.Source.PHONE
    // go2rtc: learn its two streams first (the detail and the everyday one), then test the detail one.
    if (!phone && Settings.cameraKind.value == Settings.KIND_GO2RTC && !App.demo) StreamDiscovery.run(Settings.host.value.trim())
    val client = try { testClient(context) } catch (e: Exception) {
        return TestState(connect = TestCheck.FAIL, error = friendly(e, phone))
    }
    try {
        val tracks = try { client.start() } catch (e: Exception) {
            return TestState(connect = TestCheck.FAIL, error = friendly(e, phone))
        }
        if (phone && client.serverAddresses.isNotEmpty()) Settings.setBabyAddresses(client.serverAddresses)
        val video = tracks.firstOrNull { it.sdp.kind == "video" }
        val audio = tracks.firstOrNull { it.sdp.kind == "audio" }
        partial(TestState(connect = TestCheck.OK))

        val depacketizer = H264Depacketizer()
        video?.sdp?.h264ParameterSets?.let { (s, p) -> depacketizer.setParameterSets(s, p) }
        var frames = 0
        var sounds = 0
        val stopped = AtomicBoolean(false)
        var error: String? = null
        val timer = Thread {
            try { Thread.sleep(4000) } catch (_: InterruptedException) {}
            stopped.set(true)
            client.close()
        }.apply { isDaemon = true; start() }
        try {
            client.play { channel, bytes ->
                val p = RtpPacket.parse(bytes) ?: return@play
                if (channel == video?.channel) { if (depacketizer.push(p) != null) frames++ }
                else if (channel == audio?.channel) sounds++
                // Enough of both: done early.
                if ((video == null || frames >= 3) && (audio == null || sounds >= 10)) { stopped.set(true); client.close() }
            }
        } catch (e: Exception) {
            if (!stopped.get()) error = e.message
        } finally {
            timer.interrupt()
        }
        Log.add("test: $frames frames, $sounds sound packets")
        val videoWhy = when {
            video == null && phone -> "Telefon u miminka je nastavený jen na zvuk."
            video == null -> "Kamera neposílá obraz ve formátu, kterému Chůvička rozumí (H.264). Zapněte ho v aplikaci kamery."
            else -> "Obraz nedorazil. Zkuste to znovu."
        }
        val audioWhy = when {
            audio == null && phone -> "Telefon u miminka neposílá zvuk."
            audio == null -> "Kamera posílá zvuk ve formátu, kterému Chůvička nerozumí. V aplikaci kamery přepněte zvuk na G.711."
            else -> "Zvuk nedorazil. Zkuste to znovu."
        }
        return TestState(
            connect = TestCheck.OK,
            video = if (frames > 0) TestCheck.OK else TestCheck.FAIL,
            audio = if (sounds > 0) TestCheck.OK else TestCheck.FAIL,
            videoWhy = videoWhy, audioWhy = audioWhy,
            error = error,
        )
    } finally {
        client.close()
    }
}

/** The error in words for people. */
private fun friendly(e: Exception, phone: Boolean): String {
    val m = e.message ?: ""
    return when {
        m.startsWith("Server odpověděl 404") -> if (phone) "Telefon u miminka tento kód nezná." else "Kamera tuto adresu nezná. Zkontrolujte značku kamery."
        m.startsWith("Stream nemá") -> "Obraz i zvuk přicházejí ve formátu, který Chůvička neumí přehrát."
        e is RtspClient.Failure && m.isNotEmpty() -> m          // Our own words.
        phone -> "Telefon u miminka se nepodařilo zastihnout. Běží na něm vysílání a je na stejné Wi-Fi?"
        else -> "Kameru se nepodařilo zastihnout. Zkontrolujte adresu a že je kamera zapnutá a na stejné Wi-Fi."
    }
}
