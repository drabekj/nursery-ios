package cz.drabek.chuvicka.parent

import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import cz.drabek.chuvicka.Log
import cz.drabek.chuvicka.proto.AccessUnit
import cz.drabek.chuvicka.proto.H264Depacketizer
import cz.drabek.chuvicka.proto.H264Sps
import cz.drabek.chuvicka.proto.RtpPacket
import cz.drabek.chuvicka.proto.RtspClient
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.nio.ByteBuffer

/**
 * One photo from a direct IP camera, which has no photo URL like go2rtc: a short RTSP session until
 * the first keyframe, TEARDOWN, and the keyframe decoded to a JPEG (MediaCodec with no surface).
 * Blocking: call it on Dispatchers.IO.
 */
object FrameGrabber {
    private val START = byteArrayOf(0, 0, 0, 1)

    fun grab(url: String, timeoutMs: Long = 8000): ByteArray? {
        val client = try { RtspClient.forUrl(url, directCamera = true) } catch (e: Exception) {
            Log.add("photo: ${e.message}")
            return null
        }
        // The camera may send no keyframe: give up after timeoutMs. close() sends TEARDOWN.
        val timer = Thread {
            try { Thread.sleep(timeoutMs); client.close() } catch (_: InterruptedException) {}
        }.apply { isDaemon = true; name = "photo-timer"; start() }
        try {
            val tracks = client.start()
            val video = tracks.firstOrNull { it.sdp.kind == "video" } ?: run {
                Log.add("photo: the camera sends no H.264 picture")
                return null
            }
            val depacketizer = H264Depacketizer()
            video.sdp.h264ParameterSets?.let { (s, p) -> depacketizer.setParameterSets(s, p) }
            var key: AccessUnit? = null
            try {
                client.play { channel, bytes ->
                    if (key != null || channel != video.channel) return@play
                    val p = RtpPacket.parse(bytes) ?: return@play
                    val unit = depacketizer.push(p) ?: return@play
                    if (unit.keyframe) {
                        key = unit
                        client.close()          // TEARDOWN at once: the session is not needed any more.
                    }
                }
            } catch (e: IOException) {
                if (key == null) throw e
            }
            val unit = key ?: run { Log.add("photo: no keyframe in ${timeoutMs / 1000} s"); return null }
            val sps = depacketizer.sps
            val pps = depacketizer.pps
            if (sps == null || pps == null) { Log.add("photo: no SPS/PPS"); return null }
            return decode(unit, sps, pps).also { if (it == null) Log.add("photo: the decoder gave no picture") }
        } catch (e: Exception) {
            Log.add("photo failed: ${e.message ?: e.javaClass.simpleName}")
            return null
        } finally {
            timer.interrupt()
            client.close()
        }
    }

    /** One keyframe to a JPEG. MediaCodec with no surface gives the picture as a YUV Image. */
    private fun decode(unit: AccessUnit, sps: ByteArray, pps: ByteArray): ByteArray? {
        val (width, height) = H264Sps.size(sps) ?: (1920 to 1080)
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setByteBuffer("csd-0", ByteBuffer.wrap(START + sps))
            setByteBuffer("csd-1", ByteBuffer.wrap(START + pps))
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
        }
        val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        try {
            codec.configure(format, null, null, 0)
            codec.start()
            val info = MediaCodec.BufferInfo()
            var queued = false
            var ended = false
            val deadline = System.currentTimeMillis() + 2000
            while (System.currentTimeMillis() < deadline) {
                if (!ended) {
                    val index = codec.dequeueInputBuffer(10_000)
                    if (index >= 0) {
                        val buffer = codec.getInputBuffer(index)!!
                        buffer.clear()
                        if (!queued) {
                            var size = 0
                            for (nal in unit.nals) {
                                if (buffer.remaining() < nal.size + 4) break
                                buffer.put(START); buffer.put(nal); size += nal.size + 4
                            }
                            codec.queueInputBuffer(index, 0, size, 0, MediaCodec.BUFFER_FLAG_KEY_FRAME)
                            queued = true
                        } else {
                            // The end of the stream: the decoder gives out the one frame now.
                            codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            ended = true
                        }
                    }
                }
                val out = codec.dequeueOutputBuffer(info, 10_000)
                if (out < 0) continue                    // Try again, or a new output format.
                var jpeg: ByteArray? = null
                if (info.size > 0) {
                    val image = codec.getOutputImage(out)
                    if (image != null) {
                        try { jpeg = toJpeg(image) } finally { image.close() }
                    }
                }
                codec.releaseOutputBuffer(out, false)
                if (jpeg != null) return jpeg
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
            }
            return null
        } finally {
            try { codec.stop() } catch (_: Exception) {}
            codec.release()
        }
    }

    /** A YUV_420_888 Image to NV21 (Y, then V and U in turns), then to a JPEG. Only the crop rectangle. */
    private fun toJpeg(image: Image): ByteArray {
        val crop = image.cropRect
        val w = crop.width() and 1.inv()                 // NV21 wants even sizes.
        val h = crop.height() and 1.inv()
        val nv21 = ByteArray(w * h * 3 / 2)
        val y = image.planes[0]
        val yBuffer = y.buffer
        for (row in 0 until h) {
            val start = (crop.top + row) * y.rowStride + crop.left * y.pixelStride
            if (y.pixelStride == 1) {
                yBuffer.position(start)
                yBuffer.get(nv21, row * w, w)
            } else {
                for (col in 0 until w) nv21[row * w + col] = yBuffer.get(start + col * y.pixelStride)
            }
        }
        val u = image.planes[1]
        val v = image.planes[2]
        val uBuffer = u.buffer
        val vBuffer = v.buffer
        var n = w * h
        for (row in 0 until h / 2) {
            val uStart = (crop.top / 2 + row) * u.rowStride + (crop.left / 2) * u.pixelStride
            val vStart = (crop.top / 2 + row) * v.rowStride + (crop.left / 2) * v.pixelStride
            for (col in 0 until w / 2) {
                nv21[n++] = vBuffer.get(vStart + col * v.pixelStride)
                nv21[n++] = uBuffer.get(uStart + col * u.pixelStride)
            }
        }
        val stream = ByteArrayOutputStream()
        YuvImage(nv21, ImageFormat.NV21, w, h, null).compressToJpeg(Rect(0, 0, w, h), 85, stream)
        return stream.toByteArray()
    }
}
