package cz.drabek.chuvicka.ui

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import cz.drabek.chuvicka.App
import cz.drabek.chuvicka.Net
import cz.drabek.chuvicka.PairLink
import cz.drabek.chuvicka.Settings
import cz.drabek.chuvicka.baby.BABY_PORT
import cz.drabek.chuvicka.baby.BabyState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

object Qr {
    /** A QR code, black on white, with a quiet zone. */
    fun bitmap(text: String, px: Int): Bitmap? = try {
        val m = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, px, px, mapOf(EncodeHintType.MARGIN to 2))
        val w = m.width
        val h = m.height
        val pixels = IntArray(w * h)
        for (y in 0 until h) for (x in 0 until w) {
            pixels[y * w + x] = if (m.get(x, y)) android.graphics.Color.BLACK else android.graphics.Color.WHITE
        }
        Bitmap.createBitmap(pixels, w, h, Bitmap.Config.ARGB_8888)
    } catch (e: Exception) {
        null
    }
}

/** The pairing link of this phone at the baby: its name, its code, and its addresses. */
@Composable
fun rememberPairLink(): String {
    val name by Settings.unitName.collectAsState()
    val code by Settings.unitCode.collectAsState()
    val port by BabyState.port.collectAsState()
    var addresses by remember { mutableStateOf<List<String>>(emptyList()) }
    // The addresses change with the Wi-Fi and with Tailscale: read them again now and then.
    LaunchedEffect(Unit) {
        while (true) {
            addresses = if (App.demo) listOf("100.101.102.103", "192.168.0.42") else withContext(Dispatchers.IO) { Net.ipv4() }
            delay(5000)
        }
    }
    val p = if (port > 0) port else BABY_PORT
    return PairLink.build(name.trim().ifEmpty { "Pokojíček" }.take(40), code, addresses.map { "$it:$p" })
}

/** The QR code for the parent's phone, on a white card. */
@Composable
fun PairQr(size: Dp = 220.dp, label: String? = "Naskenujte telefonem rodiče", labelColor: Color? = null) {
    val link = rememberPairLink()
    val px = with(LocalDensity.current) { size.roundToPx() }
    val bitmap = remember(link, px) { Qr.bitmap(link, px) }
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.clip(RoundedCornerShape(20.dp)).background(Color.White).padding(8.dp), contentAlignment = Alignment.Center) {
            if (bitmap != null) {
                Image(bitmap.asImageBitmap(), "QR kód pro spárování", Modifier.size(size), filterQuality = FilterQuality.None)
            } else {
                Spacer(Modifier.size(size))
            }
        }
        if (label != null) {
            Spacer(Modifier.height(8.dp))
            Text(label, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, color = labelColor ?: colors.ink)
        }
    }
}
