package cz.drabek.chuvicka.proto

import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.random.Random

// The pure protocol layer: SDP, RTP, H.264 (RFC 6184), and G.711.
// It is the same algorithm as Nursery/Stream/RTP.swift of the iOS app, so both apps
// speak exactly the same stream. Tools/rtsp_check.py tests the algorithm against go2rtc.

/** The Bonjour (mDNS) type of the phone at the baby. The iOS app uses the same type. */
const val BABY_SERVICE_TYPE = "_chuvicka._tcp"

// MARK: SDP

data class SdpTrack(
    val kind: String,          // "video", "audio", or another
    val payloadType: Int,
    val codec: String,         // Upper case, for example "H264" or "PCMA".
    val clockRate: Int,
    val control: String,
    val fmtp: Map<String, String>,
) {
    /** The SPS and the PPS from `sprop-parameter-sets`, if the SDP has them. java.util.Base64, so the unit tests run it. */
    val h264ParameterSets: Pair<ByteArray, ByteArray>?
        get() {
            val sprop = fmtp["sprop-parameter-sets"] ?: return null
            var sps: ByteArray? = null
            var pps: ByteArray? = null
            for (part in sprop.split(",")) {
                val bytes = try { java.util.Base64.getDecoder().decode(part.trim()) } catch (e: IllegalArgumentException) { continue }
                if (bytes.isEmpty()) continue
                when (bytes[0].toInt() and 0x1F) {
                    7 -> sps = bytes
                    8 -> pps = bytes
                }
            }
            return if (sps != null && pps != null) sps!! to pps!! else null
        }
}

object Sdp {
    fun parse(text: String): List<SdpTrack> {
        val sections = mutableListOf<MutableList<String>>()
        for (line in text.replace("\r", "").split("\n")) {
            if (line.startsWith("m=")) sections.add(mutableListOf(line))
            else sections.lastOrNull()?.add(line)
        }
        return sections.mapNotNull { section ->
            val m = section[0].removePrefix("m=").split(" ")
            val pt = m.getOrNull(3)?.toIntOrNull() ?: return@mapNotNull null
            var codec = ""
            var rate = 0
            var control = ""
            val fmtp = mutableMapOf<String, String>()
            for (line in section.drop(1)) {
                when {
                    line.startsWith("a=rtpmap:$pt ") -> {
                        val parts = line.substringAfter(" ").split("/")
                        codec = parts[0].uppercase()
                        rate = parts.getOrNull(1)?.toIntOrNull() ?: 0
                    }
                    line.startsWith("a=fmtp:$pt ") -> {
                        for (item in line.substringAfter(" ").split(";")) {
                            val kv = item.trim()
                            val eq = kv.indexOf('=')
                            // Split at the first "=" only. Base64 values end with "=".
                            if (eq > 0) fmtp[kv.substring(0, eq).lowercase()] = kv.substring(eq + 1)
                        }
                    }
                    line.startsWith("a=control:") -> control = line.removePrefix("a=control:")
                }
            }
            if (codec.isEmpty()) when (pt) {         // The static payload types have no rtpmap line.
                0 -> { codec = "PCMU"; rate = 8000 }
                8 -> { codec = "PCMA"; rate = 8000 }
            }
            SdpTrack(m[0], pt, codec, rate, control, fmtp)
        }
    }

    /** The URL for SETUP. go2rtc sends no Content-Base, so the request URL is the base. */
    fun controlUrl(base: String, control: String): String = when {
        control.isEmpty() || control == "*" -> base
        control.lowercase().startsWith("rtsp://") -> control
        base.endsWith("/") -> base + control
        else -> "$base/$control"
    }
}

// MARK: RTP

class RtpPacket(val payloadType: Int, val marker: Boolean, val sequence: Int, val timestamp: Long,
                val data: ByteArray, val offset: Int, val length: Int) {
    companion object {
        fun parse(b: ByteArray): RtpPacket? {
            if (b.size < 12 || (b[0].toInt() and 0xFF) shr 6 != 2) return null
            val csrc = b[0].toInt() and 0x0F
            var start = 12 + 4 * csrc
            var end = b.size
            if (b[0].toInt() and 0x10 != 0) {          // The header extension.
                if (b.size < start + 4) return null
                start += 4 + 4 * (((b[start + 2].toInt() and 0xFF) shl 8) or (b[start + 3].toInt() and 0xFF))
            }
            if (b[0].toInt() and 0x20 != 0) end -= b.last().toInt() and 0xFF   // The padding.
            if (start > end) return null
            val ts = ((b[4].toLong() and 0xFF) shl 24) or ((b[5].toLong() and 0xFF) shl 16) or
                ((b[6].toLong() and 0xFF) shl 8) or (b[7].toLong() and 0xFF)
            return RtpPacket(b[1].toInt() and 0x7F, b[1].toInt() and 0x80 != 0,
                ((b[2].toInt() and 0xFF) shl 8) or (b[3].toInt() and 0xFF), ts, b, start, end - start)
        }
    }
}

/** It makes RTP packets (RFC 3550) for one track of one receiver. */
class RtpPacketizer(private val payloadType: Int) {
    private val ssrc = Random.nextInt()
    private var sequence = Random.nextInt(0, 65536)

    fun packet(payload: ByteArray, offset: Int, length: Int, timestamp: Long, marker: Boolean, prefix: ByteArray? = null): ByteArray {
        val extra = prefix?.size ?: 0
        val b = ByteArray(12 + extra + length)
        b[0] = 0x80.toByte()
        b[1] = ((if (marker) 0x80 else 0) or payloadType).toByte()
        b[2] = (sequence shr 8).toByte(); b[3] = sequence.toByte()
        for (i in 0..3) b[4 + i] = (timestamp shr (24 - 8 * i)).toByte()
        for (i in 0..3) b[8 + i] = (ssrc shr (24 - 8 * i)).toByte()
        prefix?.copyInto(b, 12)
        System.arraycopy(payload, offset, b, 12 + extra, length)
        sequence = (sequence + 1) and 0xFFFF
        return b
    }

    /** The packets of one access unit: a single NAL unit, or FU-A fragments. */
    fun h264(nals: List<ByteArray>, timestamp: Long, maxPayload: Int = 1400): List<ByteArray> {
        val out = ArrayList<ByteArray>()
        for ((n, nal) in nals.withIndex()) {
            if (nal.isEmpty()) continue
            val last = n == nals.size - 1
            if (nal.size <= maxPayload) { out.add(packet(nal, 0, nal.size, timestamp, last)); continue }
            val header = nal[0].toInt() and 0xFF
            val indicator = (header and 0xE0) or 28
            var offset = 1
            while (offset < nal.size) {
                val end = min(offset + maxPayload - 2, nal.size)
                var fu = header and 0x1F
                if (offset == 1) fu = fu or 0x80                // The start bit.
                if (end == nal.size) fu = fu or 0x40            // The end bit.
                out.add(packet(nal, offset, end - offset, timestamp, last && end == nal.size,
                    byteArrayOf(indicator.toByte(), fu.toByte())))
                offset = end
            }
        }
        return out
    }
}

/** One RTP packet in the RTSP interleaved frame ("$", channel, length). */
fun interleaved(packet: ByteArray, channel: Int): ByteArray {
    val b = ByteArray(4 + packet.size)
    b[0] = 0x24; b[1] = channel.toByte(); b[2] = (packet.size shr 8).toByte(); b[3] = packet.size.toByte()
    packet.copyInto(b, 4)
    return b
}

// MARK: H.264

class AccessUnit(val nals: List<ByteArray>, val timestamp: Long, val keyframe: Boolean)

/** It joins the RTP packets of one frame. After a lost packet, it waits for the next keyframe. */
class H264Depacketizer {
    var sps: ByteArray? = null; private set
    var pps: ByteArray? = null; private set
    var parameterVersion = 0; private set

    private val nals = ArrayList<ByteArray>()
    private var fragment: java.io.ByteArrayOutputStream? = null
    private var timestamp: Long? = null
    private var lastSequence: Int? = null
    private var damaged = false
    private var waitForKeyframe = false

    fun setParameterSets(sps: ByteArray, pps: ByteArray) {
        if (!sps.contentEquals(this.sps) || !pps.contentEquals(this.pps)) {
            this.sps = sps; this.pps = pps; parameterVersion++
        }
    }

    fun push(p: RtpPacket): AccessUnit? {
        var output: AccessUnit? = null
        val last = lastSequence
        if (last != null && p.sequence != ((last + 1) and 0xFFFF)) { damaged = true; fragment = null }
        lastSequence = p.sequence
        val ts = timestamp
        if (ts != null && ts != p.timestamp && nals.isNotEmpty()) output = flush()   // A frame had no marker.
        timestamp = p.timestamp
        if (p.length == 0) return output
        val d = p.data
        val o = p.offset
        val first = d[o].toInt() and 0xFF
        when (val type = first and 0x1F) {
            in 1..23 -> add(d.copyOfRange(o, o + p.length))
            24 -> {                                     // STAP-A
                var i = o + 1
                val end = o + p.length
                while (i + 2 <= end) {
                    val size = ((d[i].toInt() and 0xFF) shl 8) or (d[i + 1].toInt() and 0xFF)
                    i += 2
                    if (size == 0 || i + size > end) break
                    add(d.copyOfRange(i, i + size)); i += size
                }
            }
            28 -> if (p.length >= 2) {                  // FU-A
                val header = d[o + 1].toInt() and 0xFF
                if (header and 0x80 != 0) {
                    fragment = java.io.ByteArrayOutputStream(p.length * 8).apply {
                        write((first and 0xE0) or (header and 0x1F))
                    }
                }
                fragment?.write(d, o + 2, p.length - 2)
                if (header and 0x40 != 0) {
                    fragment?.let { add(it.toByteArray()) }
                    fragment = null
                }
            }
            else -> {}
        }
        if (p.marker && nals.isNotEmpty()) output = flush()
        return output
    }

    private fun add(nal: ByteArray) {
        when (nal[0].toInt() and 0x1F) {
            7 -> if (!nal.contentEquals(sps)) { sps = nal; parameterVersion++ }
            8 -> if (!nal.contentEquals(pps)) { pps = nal; parameterVersion++ }
            9 -> {}                                     // The access unit delimiter.
            else -> nals.add(nal)
        }
    }

    private fun flush(): AccessUnit? {
        val list = ArrayList(nals)
        nals.clear()
        val wasDamaged = damaged
        damaged = false
        val ts = timestamp
        if (wasDamaged || ts == null) { waitForKeyframe = true; return null }
        val key = list.any { it[0].toInt() and 0x1F == 5 }
        if (list.none { (it[0].toInt() and 0x1F) in 1..5 }) return null
        if (waitForKeyframe) {
            if (!key) return null
            waitForKeyframe = false
        }
        return AccessUnit(list, ts, key)
    }
}

/**
 * The picture size from an H.264 SPS (ITU-T H.264, 7.3.2.1.1), after the cropping.
 * Null when the bytes are not a readable SPS. The app uses it to tell the main stream from the sub stream.
 */
object H264Sps {
    private val HIGH_PROFILES = setOf(100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135)

    fun size(sps: ByteArray): Pair<Int, Int>? = try { parse(sps) } catch (_: IllegalArgumentException) { null }

    private fun parse(sps: ByteArray): Pair<Int, Int> {
        val r = Bits(unescape(sps))
        require(r.bits(8) and 0x1F == 7)
        val profile = r.bits(8)
        r.bits(16)                                      // The constraint flags and level_idc.
        r.ue()                                          // seq_parameter_set_id
        var chroma = 1
        var separatePlanes = 0
        if (profile in HIGH_PROFILES) {
            val c = r.ue()
            require(c <= 3)
            chroma = c.toInt()
            if (chroma == 3) separatePlanes = r.bit()
            r.ue(); r.ue()                              // The bit depths.
            r.bit()                                     // qpprime_y_zero_transform_bypass_flag
            if (r.bit() == 1) {                         // seq_scaling_matrix_present_flag
                val lists = if (chroma != 3) 8 else 12
                for (i in 0 until lists) {
                    if (r.bit() == 1) skipScalingList(r, if (i < 6) 16 else 64)
                }
            }
        }
        r.ue()                                          // log2_max_frame_num_minus4
        when (r.ue()) {                                 // pic_order_cnt_type
            0L -> r.ue()                                // log2_max_pic_order_cnt_lsb_minus4
            1L -> {
                r.bit(); r.se(); r.se()
                val cycle = r.ue()
                require(cycle <= 255)
                repeat(cycle.toInt()) { r.se() }
            }
            2L -> {}
            else -> throw IllegalArgumentException("pic_order_cnt_type")
        }
        r.ue()                                          // max_num_ref_frames
        r.bit()                                         // gaps_in_frame_num_value_allowed_flag
        val widthMbs = r.ue() + 1
        val heightMapUnits = r.ue() + 1
        val frameMbsOnly = r.bit()
        if (frameMbsOnly == 0) r.bit()                  // mb_adaptive_frame_field_flag
        r.bit()                                         // direct_8x8_inference_flag
        var left = 0L; var right = 0L; var top = 0L; var bottom = 0L
        if (r.bit() == 1) { left = r.ue(); right = r.ue(); top = r.ue(); bottom = r.ue() }
        // The crop unit: 1 pixel without chroma, else the chroma subsampling. Fields double it vertically.
        val chromaType = if (separatePlanes == 1) 0 else chroma
        val (subWidth, subHeight) = when (chromaType) { 1 -> 2 to 2; 2 -> 2 to 1; else -> 1 to 1 }
        val cropX = subWidth
        val cropY = subHeight * (2 - frameMbsOnly)
        val width = widthMbs * 16 - cropX * (left + right)
        val height = (2 - frameMbsOnly) * heightMapUnits * 16 - cropY * (top + bottom)
        require(width in 1L..16384L && height in 1L..16384L)
        return width.toInt() to height.toInt()
    }

    private fun skipScalingList(r: Bits, size: Int) {
        var last = 8L
        var next = 8L
        repeat(size) {
            if (next != 0L) next = ((last + r.se()) % 256 + 256) % 256
            if (next != 0L) last = next
        }
    }

    /** The SPS without the emulation prevention bytes: 00 00 03 is 00 00. */
    internal fun unescape(b: ByteArray): ByteArray {
        val out = ByteArray(b.size)
        var n = 0
        var zeros = 0
        for (x in b) {
            val v = x.toInt() and 0xFF
            if (zeros >= 2 && v == 3) { zeros = 0; continue }
            out[n++] = x
            zeros = if (v == 0) zeros + 1 else 0
        }
        return out.copyOf(n)
    }

    /** A bit reader with Exp-Golomb codes. At the end of the data it throws IllegalArgumentException. */
    private class Bits(private val b: ByteArray) {
        private var pos = 0

        fun bit(): Int {
            require(pos < b.size * 8) { "end of the SPS" }
            val v = (b[pos ushr 3].toInt() shr (7 - (pos and 7))) and 1
            pos++
            return v
        }

        fun bits(n: Int): Int {
            var v = 0
            repeat(n) { v = (v shl 1) or bit() }
            return v
        }

        fun ue(): Long {
            var zeros = 0
            while (bit() == 0) { zeros++; require(zeros <= 32) }
            var v = 0L
            repeat(zeros) { v = (v shl 1) or bit().toLong() }
            return (1L shl zeros) - 1 + v
        }

        fun se(): Long {
            val k = ue()
            return if (k and 1L == 1L) (k + 1) / 2 else -(k / 2)
        }
    }
}

/** It splits Annex-B output (start codes) into NAL units. MediaCodec gives this format. */
fun splitAnnexB(b: ByteArray, offset: Int, length: Int): List<ByteArray> {
    val out = ArrayList<ByteArray>()
    val end = offset + length
    var i = offset
    var start = -1
    while (i + 3 <= end) {
        val three = b[i].toInt() == 0 && b[i + 1].toInt() == 0 && b[i + 2].toInt() == 1
        if (three) {
            if (start >= 0) {
                var stop = i
                if (stop > start && b[stop - 1].toInt() == 0) stop--      // A 4-byte start code.
                if (stop > start) out.add(b.copyOfRange(start, stop))
            }
            i += 3
            start = i
        } else i++
    }
    if (start in offset until end) out.add(b.copyOfRange(start, end))
    return out
}

// MARK: G.711

object G711 {
    val aLaw = ShortArray(256) { decodeALaw(it) }
    val uLaw = ShortArray(256) { decodeULaw(it) }

    private fun decodeALaw(value: Int): Short {
        val a = value xor 0x55
        var t = (a and 0x0F) shl 4
        val segment = (a and 0x70) shr 4
        when (segment) {
            0 -> t += 8
            1 -> t += 0x108
            else -> { t += 0x108; t = t shl (segment - 1) }
        }
        return (if (a and 0x80 != 0) t else -t).toShort()
    }

    private fun decodeULaw(value: Int): Short {
        val u = value.inv() and 0xFF
        var t = ((u and 0x0F) shl 3) + 0x84
        t = t shl ((u and 0x70) shr 4)
        return (if (u and 0x80 != 0) 0x84 - t else t - 0x84).toShort()
    }

    /** Linear PCM to A-law, as in the ITU reference (g711.c, linear2alaw). */
    fun encodeALaw(pcm: Short): Byte {
        var p = pcm.toInt() shr 3
        val mask: Int
        if (p >= 0) mask = 0xD5 else { mask = 0x55; p = -p - 1 }
        val ends = intArrayOf(0x1F, 0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF)
        var segment = 0
        while (segment < 8 && p > ends[segment]) segment++
        if (segment >= 8) return (0x7F xor mask).toByte()
        var a = segment shl 4
        a = a or (if (segment < 2) (p shr 1) and 0x0F else (p shr segment) and 0x0F)
        return (a xor mask).toByte()
    }
}

/** The RMS to 0...1 on a dB scale: -58 dBFS is silence, -12 dBFS is a cry. As in the iOS app. */
fun levelFromRms(rms: Double): Float {
    val db = 20 * log10(max(rms, 1e-6))
    return min(1.0, max(0.0, (db + 58) / 46)).toFloat()
}
