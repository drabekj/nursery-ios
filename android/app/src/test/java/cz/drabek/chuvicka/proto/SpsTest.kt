package cz.drabek.chuvicka.proto

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.Base64

class SpsTest {
    /** A bit writer with Exp-Golomb codes, to build an SPS field by field. */
    private class Writer {
        private val list = ArrayList<Int>()
        fun bit(v: Int) = apply { list.add(v and 1) }
        fun bits(v: Int, n: Int) = apply { for (i in n - 1 downTo 0) bit(v shr i) }
        fun ue(v: Int) = apply {
            val x = v + 1
            val len = 32 - Integer.numberOfLeadingZeros(x)
            bits(0, len - 1); bits(x, len)
        }
        fun se(v: Int) = ue(if (v > 0) 2 * v - 1 else -2 * v)
        /** The stop bit, the zero padding, then the emulation prevention bytes, as a camera sends it. */
        fun sps(): ByteArray {
            bit(1)
            while (list.size % 8 != 0) bit(0)
            val raw = ByteArray(list.size / 8) { i -> (0 until 8).fold(0) { a, j -> (a shl 1) or list[i * 8 + j] }.toByte() }
            val out = java.io.ByteArrayOutputStream()
            var zeros = 0
            for (x in raw) {
                val v = x.toInt() and 0xFF
                if (zeros >= 2 && v <= 3) { out.write(3); zeros = 0 }
                out.write(v)
                zeros = if (v == 0) zeros + 1 else 0
            }
            return out.toByteArray()
        }
    }

    private fun sps(b64: String) = Base64.getDecoder().decode(b64)

    @Test
    fun baselineCroppedFrom368() {
        val w = Writer().bits(0x67, 8).bits(66, 8).bits(0, 8).bits(30, 8)
            .ue(0)                  // sps id
            .ue(0)                  // log2_max_frame_num_minus4
            .ue(0).ue(0)            // pic_order_cnt_type 0, its lsb size
            .ue(1).bit(0)           // ref frames, gaps
            .ue(39).ue(22)          // 40 × 23 macroblocks: 640 × 368
            .bit(1).bit(1)          // frame_mbs_only, direct_8x8
            .bit(1).ue(0).ue(0).ue(0).ue(4)     // Cropped 4 × 2 rows at the bottom.
            .bit(0)                 // No VUI.
        assertEquals(640 to 360, H264Sps.size(w.sps()))
    }

    @Test
    fun highWithScalingListsCroppedFrom1088() {
        val w = Writer().bits(0x67, 8).bits(100, 8).bits(0, 8).bits(40, 8)
            .ue(0)
            .ue(1).ue(0).ue(0).bit(0)           // 4:2:0, 8 bits, no bypass
            .bit(1)                             // The scaling matrix.
            .bit(1).se(-8)                      // List 0: the default one, one delta only.
        repeat(5) { w.bit(0) }
        w.bit(1); repeat(64) { w.se(1) }        // List 6: all 64 deltas.
        w.bit(0)
        w.ue(0)
            .ue(1).bit(0).se(0).se(0).ue(2).se(1).se(-1)     // pic_order_cnt_type 1 with a cycle of 2
            .ue(4).bit(0)
            .ue(119).ue(67)                     // 120 × 68 macroblocks: 1920 × 1088
            .bit(1).bit(1)
            .bit(1).ue(0).ue(0).ue(0).ue(4)
            .bit(0)
        assertEquals(1920 to 1080, H264Sps.size(w.sps()))
    }

    @Test
    fun interlacedDoublesTheHeight() {
        val w = Writer().bits(0x67, 8).bits(77, 8).bits(0, 8).bits(40, 8)
            .ue(0).ue(0).ue(2)                  // pic_order_cnt_type 2
            .ue(2).bit(0)
            .ue(119).ue(33)                     // 34 map units of 2 × 16 rows: 1088
            .bit(0).bit(1)                      // Fields, mb_adaptive_frame_field
            .bit(1)
            .bit(1).ue(0).ue(0).ue(0).ue(2)     // 2 × 4 rows
            .bit(0)
        assertEquals(1920 to 1080, H264Sps.size(w.sps()))
    }

    /** Real SPS from x264 (ffmpeg testsrc), with emulation prevention bytes. ffprobe gave the sizes. */
    @Test
    fun realEncoderOutput() {
        assertEquals(640 to 360, H264Sps.size(sps("Z2QAFqzZQKAv+XARAAADAAEAAAMACg8WLZY=")))
        assertEquals(1920 to 1080, H264Sps.size(sps("Z2QAKKzZQHgCJ+XARAAAAwAEAAADACg8YMZY")))
        assertEquals(1280 to 720, H264Sps.size(sps("Z0LAH9kAUAW7ARAAAAMAEAAAAwCg8YMkgA==")))
        assertEquals(2560 to 1440, H264Sps.size(sps("Z01AMuygFABa2AiAAAADAIAAAAUHjBjL")))
        assertEquals(720 to 576, H264Sps.size(sps("Z3oAFrzZQLQk2AiAAAADAIAAAAUPihTL")))    // 4:2:2, interlaced
    }

    @Test
    fun removesEmulationPrevention() {
        val b = byteArrayOf(0x67, 0, 0, 3, 1, 0, 0, 3, 0, 0, 3)
        assertArrayEquals(byteArrayOf(0x67, 0, 0, 1, 0, 0, 0, 0), H264Sps.unescape(b))
    }

    @Test
    fun garbageIsNull() {
        assertNull(H264Sps.size(ByteArray(0)))
        assertNull(H264Sps.size(byteArrayOf(0x68, 0x11, 0x22)))            // A PPS, not an SPS.
        assertNull(H264Sps.size(byteArrayOf(0x67, 0x64, 0x00)))            // Cut short.
        assertNull(H264Sps.size(byteArrayOf(0x67, 66, 0, 30) + ByteArray(20)))     // Only zero bits: no Exp-Golomb end.
        val real = sps("Z2QAKKzZQHgCJ+XARAAAAwAEAAADACg8YMZY")
        assertNull(H264Sps.size(real.copyOf(8)))
    }
}
