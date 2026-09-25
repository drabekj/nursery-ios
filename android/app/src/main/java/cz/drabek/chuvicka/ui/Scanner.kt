package cz.drabek.chuvicka.ui

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.SurfaceTexture
import android.util.Size
import android.view.Surface
import android.view.TextureView
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceRequest
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.ReaderException
import com.google.zxing.common.HybridBinarizer
import cz.drabek.chuvicka.App
import cz.drabek.chuvicka.Log
import cz.drabek.chuvicka.PairLink
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The QR scanner for the pairing link of the phone at the baby. It asks for the camera first.
 * [found] gets a valid link once; other QR codes only show a hint.
 */
@Composable
fun QrScanner(found: (PairLink.Info) -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    var granted by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    var denied by remember { mutableStateOf(false) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        granted = ok
        denied = !ok
    }
    LaunchedEffect(Unit) { if (!granted && !App.demo) ask.launch(Manifest.permission.CAMERA) }
    var wrongCode by remember { mutableStateOf(false) }

    Column(modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.fillMaxWidth().aspectRatio(3f / 4f).clip(RoundedCornerShape(26.dp)).background(Color.Black),
            contentAlignment = Alignment.Center) {
            when {
                granted && !App.demo -> CameraView(found, onOtherCode = { wrongCode = true })
                denied -> Column(Modifier.padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("Bez přístupu k fotoaparátu QR kód nenačtete.", color = Color.White, textAlign = TextAlign.Center)
                    Spacer(Modifier.height(8.dp))
                    Text("Povolte ho v Nastavení telefonu → Aplikace → Chůvička, nebo zadejte kód ručně.",
                        color = Color.White.copy(alpha = 0.7f), textAlign = TextAlign.Center)
                    TextButton(onClick = { ask.launch(Manifest.permission.CAMERA) }) { Text("Zkusit znovu", color = DarkPalette.moon) }
                }
                App.demo -> Icon(Icons.Filled.QrCodeScanner, null, Modifier.size(96.dp), tint = Color.White.copy(alpha = 0.6f))
                else -> CircularProgressIndicator(color = Color.White)
            }
            // The frame to aim with.
            Box(Modifier.fillMaxSize(0.62f).aspectRatio(1f).clip(RoundedCornerShape(24.dp)).background(Color.White.copy(alpha = 0.08f)))
        }
        Spacer(Modifier.height(10.dp))
        Text(if (wrongCode) "Tohle není QR kód Chůvičky. Namiřte na kód na druhém telefonu."
             else "Namiřte fotoaparát na QR kód na druhém telefonu.",
            color = if (wrongCode) colors.warn else colors.muted, textAlign = TextAlign.Center)
    }
}

/**
 * CameraX: the preview on a TextureView (the camera-view library with PreviewView is not in
 * the app), and the analysis frames to ZXing. The Y plane is the luminance that ZXing needs.
 */
@Composable
private fun CameraView(found: (PairLink.Info) -> Unit, onOtherCode: () -> Unit) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val onFound by rememberUpdatedState(found)
    val onOther by rememberUpdatedState(onOtherCode)
    var aspect by remember { mutableFloatStateOf(3f / 4f) }
    val textureView = remember { TextureView(context) }

    DisposableEffect(owner) {
        val main = ContextCompat.getMainExecutor(context)
        val executor = Executors.newSingleThreadExecutor()
        val done = AtomicBoolean(false)
        var pending: SurfaceRequest? = null
        var provider: ProcessCameraProvider? = null
        var disposed = false

        fun provide(request: SurfaceRequest, texture: SurfaceTexture) {
            val size: Size = request.resolution
            texture.setDefaultBufferSize(size.width, size.height)
            val surface = Surface(texture)
            request.provideSurface(surface, main) { surface.release() }
        }
        textureView.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
                pending?.let { provide(it, surface) }
                pending = null
            }
            override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {}
            override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean = true
            override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {}
        }

        val preview = Preview.Builder().build()
        preview.setSurfaceProvider(main) { request ->
            // The buffer comes in the sensor's orientation (landscape): in portrait, the view is tall.
            val r = request.resolution
            aspect = minOf(r.width, r.height).toFloat() / maxOf(r.width, r.height)
            val texture = textureView.surfaceTexture
            if (texture != null) provide(request, texture) else pending = request
        }

        val reader = MultiFormatReader().apply {
            setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE)))
        }
        val analysis = ImageAnalysis.Builder()
            .setResolutionSelector(ResolutionSelector.Builder()
                .setResolutionStrategy(ResolutionStrategy(Size(1280, 720), ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER))
                .build())
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .build()
        analysis.setAnalyzer(executor) { image ->
            val text = try { if (done.get()) null else decode(reader, image) } finally { image.close() }
            if (text != null) {
                val link = PairLink.parse(text)
                if (link != null) {
                    if (!done.getAndSet(true)) main.execute { onFound(link) }
                } else {
                    main.execute { onOther() }
                }
            }
        }

        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (disposed) return@addListener
            try {
                val p = future.get()
                provider = p
                p.unbindAll()
                p.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
            } catch (e: Exception) {
                Log.add("scanner camera failed: ${e.message}")
            }
        }, main)

        onDispose {
            disposed = true
            done.set(true)
            try { provider?.unbind(preview, analysis) } catch (_: Exception) {}
            analysis.clearAnalyzer()
            executor.shutdown()
        }
    }

    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        // Fill the box and crop the rest, as the camera app does.
        AndroidView(factory = { textureView }, modifier = Modifier.fillMaxWidth().aspectRatio(aspect, matchHeightConstraintsFirst = false))
    }
}

/** The text of a QR code in the frame, or null. */
private fun decode(reader: MultiFormatReader, image: ImageProxy): String? {
    val plane = image.planes[0]
    val w = image.width
    val h = image.height
    val buffer = plane.buffer
    val y = ByteArray(w * h)
    for (row in 0 until h) {
        buffer.position(row * plane.rowStride)
        buffer.get(y, row * w, w)
    }
    val source = PlanarYUVLuminanceSource(y, w, h, 0, 0, w, h, false)
    return try {
        reader.decodeWithState(BinaryBitmap(HybridBinarizer(source))).text
    } catch (e: ReaderException) {
        null
    } catch (e: Exception) {
        null
    } finally {
        reader.reset()
    }
}
