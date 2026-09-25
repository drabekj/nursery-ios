package cz.drabek.chuvicka.parent

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.view.Surface
import cz.drabek.chuvicka.Log
import cz.drabek.chuvicka.proto.AccessUnit
import cz.drabek.chuvicka.proto.G711
import cz.drabek.chuvicka.proto.H264Depacketizer
import kotlin.math.pow
import kotlin.math.tanh

/**
 * The live sound: G.711 at 8 kHz to an AudioTrack. It keeps the delay under about 0.4 s:
 * when more is waiting (after a Wi-Fi hiccup), it skips the old sound instead of lagging behind.
 * The gain of the loudness setting goes through a soft limiter, as in the iOS app.
 */
class AudioPlayer {
    private val track: AudioTrack
    private var written = 0L
    @Volatile var gainDb = 0f
    @Volatile var muted = false

    init {
        val min = AudioTrack.getMinBufferSize(8000, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        track = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build())
            .setAudioFormat(AudioFormat.Builder()
                .setSampleRate(8000)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .build())
            .setBufferSizeInBytes(maxOf(min, 8000 * 2))       // 1 s of room; the delay cap is below.
            .setTransferMode(AudioTrack.MODE_STREAM)
            .apply { if (Build.VERSION.SDK_INT >= 26) setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY) }
            .build()
        track.play()
    }

    fun play(payload: ByteArray, offset: Int, length: Int, uLaw: Boolean) {
        if (muted) return
        val buffered = written - (track.playbackHeadPosition.toLong() and 0xFFFFFFFFL)
        if (buffered > 8000 * 0.4) return                       // Too far behind: skip this packet.
        val table = if (uLaw) G711.uLaw else G711.aLaw
        val gain = 10f.pow(gainDb / 20f)
        val pcm = ShortArray(length)
        for (i in 0 until length) {
            val s = table[payload[offset + i].toInt() and 0xFF] / 32768f * gain
            // The soft limit: loud sounds stay loud, but they do not clip.
            val limited = if (gain > 1f) tanh(s) else s
            pcm[i] = (limited * 32767f).toInt().coerceIn(-32768, 32767).toShort()
        }
        val n = track.write(pcm, 0, pcm.size, AudioTrack.WRITE_NON_BLOCKING)
        if (n > 0) written += n
    }

    fun release() {
        try { track.stop() } catch (_: IllegalStateException) {}
        track.release()
    }
}

/**
 * H.264 access units to a MediaCodec decoder that draws on the screen's surface.
 * It starts at a keyframe and configures itself from the SPS and the PPS.
 */
class VideoDecoder(private val surface: Surface, private val onSize: (Int, Int) -> Unit) {
    private var codec: MediaCodec? = null
    private var version = -1
    private val info = MediaCodec.BufferInfo()

    @Synchronized
    fun push(unit: AccessUnit, depacketizer: H264Depacketizer) {
        val sps = depacketizer.sps ?: return
        val pps = depacketizer.pps ?: return
        if (codec == null || version != depacketizer.parameterVersion) {
            if (!unit.keyframe) return
            configure(sps, pps)
            version = depacketizer.parameterVersion
        }
        val c = codec ?: return
        try {
            val index = c.dequeueInputBuffer(10_000)
            if (index >= 0) {
                val buffer = c.getInputBuffer(index)!!
                buffer.clear()
                var size = 0
                for (nal in unit.nals) {
                    if (buffer.remaining() < nal.size + 4) break
                    buffer.put(START); buffer.put(nal); size += nal.size + 4
                }
                c.queueInputBuffer(index, 0, size, unit.timestamp * 1000 / 90, 0)
            }
            while (true) {
                val out = c.dequeueOutputBuffer(info, 0)
                when {
                    out >= 0 -> c.releaseOutputBuffer(out, true)       // Draw it now: the lowest delay.
                    out == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val f = c.outputFormat
                        onSize(f.getInteger(MediaFormat.KEY_WIDTH), f.getInteger(MediaFormat.KEY_HEIGHT))
                    }
                    else -> break
                }
            }
        } catch (e: Exception) {
            Log.add("decoder: ${e.message}")
            release()
        }
    }

    private fun configure(sps: ByteArray, pps: ByteArray) {
        release()
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, 1920, 1080).apply {
            setByteBuffer("csd-0", java.nio.ByteBuffer.wrap(START + sps))
            setByteBuffer("csd-1", java.nio.ByteBuffer.wrap(START + pps))
            if (Build.VERSION.SDK_INT >= 30) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        }
        val c = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        c.configure(format, surface, null, 0)
        c.start()
        codec = c
    }

    @Synchronized
    fun release() {
        val c = codec ?: return
        codec = null
        try { c.stop() } catch (_: Exception) {}
        c.release()
    }

    companion object {
        private val START = byteArrayOf(0, 0, 0, 1)
    }
}
