package cz.drabek.chuvicka.baby

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import android.os.Bundle
import android.util.Range
import android.util.Size
import android.view.Surface
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import cz.drabek.chuvicka.Log
import cz.drabek.chuvicka.proto.G711
import cz.drabek.chuvicka.proto.levelFromRms
import cz.drabek.chuvicka.proto.splitAnnexB
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.max
import kotlin.math.sqrt

/**
 * The camera and the microphone of the phone at the baby. The same stream as the iOS app sends:
 * - The picture: 1280×720 at 15 frames per second, H.264 from the hardware encoder.
 *   The camera draws straight into the encoder's input surface, so no frame passes the CPU.
 *   It encodes only while a parent takes the picture.
 * - The sound: the microphone at 8 kHz, G.711 A-law in 20 ms packets.
 * - A small analysis stream (640×360) gives the photo for the parents and the preview here.
 */
class BabyCapture(private val context: Context, private val server: BabyServer) {
    @Volatile var peak = 0f                        // The loudest level since the last read, 0...1.
    private val cameraExecutor = Executors.newSingleThreadExecutor()
    private var provider: ProcessCameraProvider? = null
    private var encoder: MediaCodec? = null
    private var encoderSurface: Surface? = null
    private val encoding = AtomicBoolean(false)
    private val frameRequest = AtomicReference<((ByteArray?) -> Unit)?>(null)
    @Volatile private var running = false
    private var audioThread: Thread? = null
    private var encoderThread: Thread? = null

    // MARK: The picture

    fun startVideo(owner: LifecycleOwner, front: Boolean) {
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            val provider = future.get()
            this.provider = provider
            val selector = ResolutionSelector.Builder()
                .setResolutionStrategy(ResolutionStrategy(Size(1280, 720), ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER))
                .build()
            val preview = Preview.Builder()
                .setResolutionSelector(selector)
                .setTargetFrameRate(Range(15, 15))
                .build()
            preview.setSurfaceProvider(cameraExecutor) { request ->
                val size = request.resolution
                val surface = makeEncoder(size.width, size.height)
                request.provideSurface(surface, cameraExecutor) { stopEncoder() }
            }
            val analysis = ImageAnalysis.Builder()
                .setResolutionSelector(ResolutionSelector.Builder()
                    .setResolutionStrategy(ResolutionStrategy(Size(640, 360), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER))
                    .build())
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            analysis.setAnalyzer(cameraExecutor) { image -> analyze(image) }
            val camera = if (front) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
            try {
                provider.unbindAll()
                provider.bindToLifecycle(owner, camera, preview, analysis)
                Log.add("baby camera on")
            } catch (e: Exception) {
                Log.add("baby camera failed: ${e.message}")
            }
        }, ContextCompat.getMainExecutor(context))
    }

    fun setEncoding(on: Boolean) {
        if (on && !encoding.getAndSet(true)) requestKeyframe()
        if (!on) encoding.set(false)
    }

    fun requestKeyframe() {
        try {
            encoder?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
        } catch (_: IllegalStateException) {}
    }

    /** The next camera frame as a JPEG, or null after 3 s. It blocks: call it on a background thread. */
    fun frame(): ByteArray? {
        val result = java.util.concurrent.ArrayBlockingQueue<Any>(1)
        frameRequest.set { jpeg -> result.offer(jpeg ?: Unit) }
        val r = result.poll(3, java.util.concurrent.TimeUnit.SECONDS)
        frameRequest.set(null)
        return r as? ByteArray
    }

    private fun analyze(image: ImageProxy) {
        val waiting = frameRequest.getAndSet(null)
        if (waiting != null) waiting(jpeg(image))
        image.close()
    }

    /** YUV_420_888 to NV21 to JPEG. Row strides and pixel strides differ between phones. */
    private fun jpeg(image: ImageProxy): ByteArray? = try {
        val w = image.width
        val h = image.height
        val nv21 = ByteArray(w * h * 3 / 2)
        val y = image.planes[0]
        var pos = 0
        for (row in 0 until h) {
            y.buffer.position(row * y.rowStride)
            y.buffer.get(nv21, pos, w)
            pos += w
        }
        val u = image.planes[1]
        val v = image.planes[2]
        for (row in 0 until h / 2) for (col in 0 until w / 2) {
            val i = row * v.rowStride + col * v.pixelStride
            nv21[pos++] = v.buffer.get(i)
            nv21[pos++] = u.buffer.get(row * u.rowStride + col * u.pixelStride)
        }
        val out = ByteArrayOutputStream()
        YuvImage(nv21, ImageFormat.NV21, w, h, null).compressToJpeg(Rect(0, 0, w, h), 75, out)
        out.toByteArray()
    } catch (e: Exception) {
        null
    }

    private fun makeEncoder(width: Int, height: Int): Surface {
        stopEncoder()
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, 1_500_000)
            setInteger(MediaFormat.KEY_FRAME_RATE, 15)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = codec.createInputSurface()
        codec.start()
        encoder = codec
        encoderSurface = surface
        running = true
        encoderThread = Thread({ drain(codec) }, "baby-encoder").apply { start() }
        Log.add("baby encoder ${width}x$height")
        return surface
    }

    /** The encoder's output: Annex-B NAL units. The codec config (SPS, PPS) comes first. */
    private fun drain(codec: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        var sps: ByteArray? = null
        var pps: ByteArray? = null
        try {
            while (running && encoder === codec) {
                val index = codec.dequeueOutputBuffer(info, 100_000)
                if (index < 0) continue
                val buffer = codec.getOutputBuffer(index)
                if (buffer != null && info.size > 0) {
                    val bytes = ByteArray(info.size)
                    buffer.position(info.offset)
                    buffer.get(bytes)
                    val nals = splitAnnexB(bytes, 0, bytes.size)
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        for (n in nals) when (n[0].toInt() and 0x1F) { 7 -> sps = n; 8 -> pps = n }
                    } else if (encoding.get()) {
                        val key = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                        val slices = nals.filter { (it[0].toInt() and 0x1F) !in 7..8 }
                        val ts = info.presentationTimeUs * 90 / 1000
                        server.sendVideo(slices, ts and 0xFFFFFFFFL, key, if (key) sps else null, if (key) pps else null)
                    }
                }
                codec.releaseOutputBuffer(index, false)
            }
        } catch (e: IllegalStateException) {
            // The codec stopped.
        }
    }

    private fun stopEncoder() {
        val codec = encoder ?: return
        encoder = null
        try { codec.stop() } catch (_: Exception) {}
        codec.release()
        encoderSurface?.release()
        encoderSurface = null
    }

    // MARK: The sound

    @SuppressLint("MissingPermission")          // The service starts only after the permission.
    fun startAudio() {
        val min = AudioRecord.getMinBufferSize(8000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val record = AudioRecord(MediaRecorder.AudioSource.MIC, 8000, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT, max(min, 3200) * 2)
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            Log.add("baby microphone failed")
            record.release()
            return
        }
        running = true
        audioThread = Thread({
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO)
            val pcm = ShortArray(160)
            var timestamp = kotlin.random.Random.nextLong(0, 0xFFFFFFFFL)
            record.startRecording()
            while (running) {
                var n = 0
                while (n < 160 && running) {
                    val r = record.read(pcm, n, 160 - n)
                    if (r < 0) break
                    n += r
                }
                if (n < 160) continue
                val packet = ByteArray(160)
                var sum = 0.0
                for (i in 0 until 160) {
                    packet[i] = G711.encodeALaw(pcm[i])
                    val f = pcm[i] / 32768.0
                    sum += f * f
                }
                peak = max(peak, levelFromRms(sqrt(sum / 160)))
                server.sendAudio(packet, timestamp)
                timestamp = (timestamp + 160) and 0xFFFFFFFFL
            }
            record.stop()
            record.release()
        }, "baby-audio").apply { start() }
    }

    fun stop() {
        running = false
        audioThread?.join(500)
        ContextCompat.getMainExecutor(context).execute { provider?.unbindAll() }
        stopEncoder()
        cameraExecutor.shutdown()
    }
}
