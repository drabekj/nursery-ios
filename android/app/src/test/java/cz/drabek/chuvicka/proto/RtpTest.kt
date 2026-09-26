package cz.drabek.chuvicka.proto

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RtpTest {
    // MARK: RtpPacket

    @Test
    fun parsesTheHeader() {
        val p = RtpPacket.parse(raw(bytes(1, 2, 3), seq = 0xABCD, ts = 0xFFFFFFFEL, marker = true, pt = 96))
        assertNotNull(p)
        assertEquals(96, p!!.payloadType)
        assertTrue(p.marker)
        assertEquals(0xABCD, p.sequence)
        assertEquals(4294967294L, p.timestamp)      // Unsigned, not negative.
        assertEquals(12, p.offset)
        assertEquals(3, p.length)
        assertArrayEquals(bytes(1, 2, 3), payload(p))
    }

    @Test
    fun noMarker() {
        val p = RtpPacket.parse(raw(bytes(1), seq = 1, pt = 8))!!
        assertFalse(p.marker)
        assertEquals(8, p.payloadType)
    }

    @Test
    fun rejectsShortInputAndOtherVersions() {
        assertNull(RtpPacket.parse(ByteArray(0)))
        assertNull(RtpPacket.parse(ByteArray(11).also { it[0] = 0x80.toByte() }))
        val v1 = raw(bytes(1), seq = 1).also { it[0] = 0x40 }
        assertNull(RtpPacket.parse(v1))
        val v3 = raw(bytes(1), seq = 1).also { it[0] = 0xC0.toByte() }
        assertNull(RtpPacket.parse(v3))
    }

    @Test
    fun skipsTheCsrcList() {
        // Two CSRCs: 8 more bytes of header.
        val b = raw(ByteArray(8) + bytes(9, 9), seq = 1).also { it[0] = 0x82.toByte() }
        val p = RtpPacket.parse(b)!!
        assertEquals(20, p.offset)
        assertArrayEquals(bytes(9, 9), payload(p))
    }

    @Test
    fun skipsTheHeaderExtension() {
        // The profile 0xBEDE, a length of one 32-bit word, the word, then the payload.
        val b = raw(bytes(0xBE, 0xDE, 0, 1, 0x11, 0x22, 0x33, 0x44, 7), seq = 1).also { it[0] = 0x90.toByte() }
        val p = RtpPacket.parse(b)!!
        assertEquals(20, p.offset)
        assertArrayEquals(bytes(7), payload(p))
    }

    @Test
    fun rejectsABrokenHeaderExtension() {
        val short = raw(bytes(0xBE, 0xDE), seq = 1).also { it[0] = 0x90.toByte() }
        assertNull(RtpPacket.parse(short))
        val tooLong = raw(bytes(0xBE, 0xDE, 0, 16, 1, 2, 3, 4), seq = 1).also { it[0] = 0x90.toByte() }
        assertNull(RtpPacket.parse(tooLong))
    }

    @Test
    fun removesThePadding() {
        // The last byte is the count of the padding bytes, itself included.
        val b = raw(bytes(5, 6, 0, 0, 3), seq = 1).also { it[0] = 0xA0.toByte() }
        val p = RtpPacket.parse(b)!!
        assertArrayEquals(bytes(5, 6), payload(p))
        val tooMuch = raw(bytes(0xFF), seq = 1).also { it[0] = 0xA0.toByte() }
        assertNull(RtpPacket.parse(tooMuch))
    }

    // MARK: H264Depacketizer

    @Test
    fun aSingleNalWithTheMarkerIsAFrame() {
        val d = H264Depacketizer()
        val idr = bytes(0x65, 1, 2, 3)
        val au = d.push(rtp(idr, seq = 1, ts = 3000, marker = true))
        assertNotNull(au)
        assertEquals(1, au!!.nals.size)
        assertArrayEquals(idr, au.nals[0])
        assertEquals(3000L, au.timestamp)
        assertTrue(au.keyframe)

        val slice = bytes(0x41, 4, 5)
        val next = d.push(rtp(slice, seq = 2, ts = 6000, marker = true))!!
        assertArrayEquals(slice, next.nals[0])
        assertFalse(next.keyframe)
    }

    @Test
    fun theSlicesOfOneFrameWaitForTheMarker() {
        val d = H264Depacketizer()
        assertNull(d.push(rtp(bytes(0x41, 1), seq = 10, ts = 100)))
        val au = d.push(rtp(bytes(0x41, 2), seq = 11, ts = 100, marker = true))!!
        assertEquals(2, au.nals.size)
        assertArrayEquals(bytes(0x41, 1), au.nals[0])
        assertArrayEquals(bytes(0x41, 2), au.nals[1])
    }

    @Test
    fun aNewTimestampEndsAFrameWithNoMarker() {
        val d = H264Depacketizer()
        assertNull(d.push(rtp(bytes(0x41, 1), seq = 1, ts = 1000)))
        val au = d.push(rtp(bytes(0x41, 2), seq = 2, ts = 2000))!!
        assertEquals(1000L, au.timestamp)
        assertEquals(1, au.nals.size)
        assertArrayEquals(bytes(0x41, 1), au.nals[0])
    }

    @Test
    fun theSequenceWrapsAround() {
        val d = H264Depacketizer()
        assertNull(d.push(rtp(bytes(0x41, 1), seq = 65535, ts = 100)))
        val au = d.push(rtp(bytes(0x41, 2), seq = 0, ts = 100, marker = true))
        assertNotNull(au)
        assertEquals(2, au!!.nals.size)
    }

    @Test
    fun splitsStapA() {
        val d = H264Depacketizer()
        val sps = bytes(0x67, 0x42, 0x00, 0x1F)
        val pps = bytes(0x68, 0xCE, 0x3C, 0x80)
        val idr = bytes(0x65, 9, 8, 7, 6)
        val stap = bytes(0x78) + sized(sps) + sized(pps) + sized(idr)   // 0x78: NRI 3, type 24.
        val au = d.push(rtp(stap, seq = 1, ts = 90, marker = true))!!
        // The parameter sets are kept apart, not in the frame.
        assertEquals(1, au.nals.size)
        assertArrayEquals(idr, au.nals[0])
        assertTrue(au.keyframe)
        assertArrayEquals(sps, d.sps)
        assertArrayEquals(pps, d.pps)
        assertEquals(2, d.parameterVersion)
    }

    @Test
    fun joinsFuA() {
        val d = H264Depacketizer()
        val nal = bytes(0x65, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9)
        // The indicator keeps F and NRI of the NAL header (0x60) with type 28: 0x7C.
        // The FU header: start 0x80, end 0x40, and the NAL type 5.
        assertNull(d.push(rtp(bytes(0x7C, 0x85, 0, 1, 2), seq = 1, ts = 500)))
        assertNull(d.push(rtp(bytes(0x7C, 0x05, 3, 4, 5, 6), seq = 2, ts = 500)))
        val au = d.push(rtp(bytes(0x7C, 0x45, 7, 8, 9), seq = 3, ts = 500, marker = true))!!
        assertEquals(1, au.nals.size)
        assertArrayEquals(nal, au.nals[0])      // The header byte 0x65 is rebuilt.
        assertTrue(au.keyframe)
    }

    @Test
    fun parameterSets() {
        val d = H264Depacketizer()
        val sps = bytes(0x67, 0x42, 0x00, 0x1F)
        val pps = bytes(0x68, 0xCE, 0x3C, 0x80)
        assertEquals(0, d.parameterVersion)
        d.setParameterSets(sps, pps)
        assertEquals(1, d.parameterVersion)
        d.setParameterSets(sps.copyOf(), pps.copyOf())      // The same content: no change.
        assertEquals(1, d.parameterVersion)

        // The same SPS in the stream: no change. Parameter sets alone are no frame.
        assertNull(d.push(rtp(sps.copyOf(), seq = 1, ts = 10, marker = true)))
        assertEquals(1, d.parameterVersion)
        val pps2 = bytes(0x68, 0xCE, 0x3C, 0x81)
        assertNull(d.push(rtp(pps2, seq = 2, ts = 10, marker = true)))
        assertEquals(2, d.parameterVersion)
        assertArrayEquals(pps2, d.pps)
    }

    @Test
    fun ignoresTheAccessUnitDelimiter() {
        val d = H264Depacketizer()
        assertNull(d.push(rtp(bytes(0x09, 0xF0), seq = 1, ts = 10)))
        val au = d.push(rtp(bytes(0x65, 1), seq = 2, ts = 10, marker = true))!!
        assertEquals(1, au.nals.size)
        assertArrayEquals(bytes(0x65, 1), au.nals[0])
    }

    @Test
    fun afterALostPacketItWaitsForAKeyframe() {
        val d = H264Depacketizer()
        assertNotNull(d.push(rtp(bytes(0x65, 1), seq = 1, ts = 1000, marker = true)))
        assertNull(d.push(rtp(bytes(0x41, 2), seq = 3, ts = 2000, marker = true)))  // Packet 2 is lost.
        assertNull(d.push(rtp(bytes(0x41, 3), seq = 4, ts = 3000, marker = true)))  // No keyframe yet.
        val au = d.push(rtp(bytes(0x65, 4), seq = 5, ts = 4000, marker = true))
        assertNotNull(au)
        assertTrue(au!!.keyframe)
        assertEquals(4000L, au.timestamp)
    }

    // MARK: RtpPacketizer and back

    @Test
    fun packetizeAndDepacketize() {
        val packetizer = RtpPacketizer(96)
        val d = H264Depacketizer()
        val sps = bytes(0x67, 0x42, 0x00, 0x1F)
        val pps = bytes(0x68, 0xCE, 0x3C, 0x80)
        val idr = ByteArray(5000) { (it * 7).toByte() }.also { it[0] = 0x65 }

        val packets = packetizer.h264(listOf(sps, pps, idr), 90000L)
        // SPS, PPS, and the IDR in FU-A fragments of at most 1398 bytes: 4999 bytes in 4.
        assertEquals(6, packets.size)
        val ssrc = packets[0].copyOfRange(8, 12)
        var au: AccessUnit? = null
        for ((i, b) in packets.withIndex()) {
            assertTrue(b.size <= 12 + 1400)
            assertArrayEquals(ssrc, b.copyOfRange(8, 12))
            val p = RtpPacket.parse(b)!!
            assertEquals(96, p.payloadType)
            assertEquals(90000L, p.timestamp)
            assertEquals(i == packets.size - 1, p.marker)
            if (i > 0) assertEquals((RtpPacket.parse(packets[i - 1])!!.sequence + 1) and 0xFFFF, p.sequence)
            val out = d.push(p)
            if (i < packets.size - 1) {
                assertNull(out)
            } else {
                au = out
            }
        }
        assertNotNull(au)
        assertEquals(1, au!!.nals.size)
        assertArrayEquals(idr, au.nals[0])
        assertTrue(au.keyframe)
        assertArrayEquals(sps, d.sps)
        assertArrayEquals(pps, d.pps)

        // The next frame from the same packetizer: two slices, one small, one large.
        val small = ByteArray(100) { it.toByte() }.also { it[0] = 0x41 }
        val large = ByteArray(3000) { (it * 3).toByte() }.also { it[0] = 0x41 }
        var next: AccessUnit? = null
        for (b in packetizer.h264(listOf(small, large), 93000L)) next = d.push(RtpPacket.parse(b)!!) ?: next
        assertNotNull(next)
        assertEquals(2, next!!.nals.size)
        assertArrayEquals(small, next.nals[0])
        assertArrayEquals(large, next.nals[1])
        assertFalse(next.keyframe)
        assertEquals(93000L, next.timestamp)
    }

    @Test
    fun theMaxPayloadBoundary() {
        val max = 100
        val fits = ByteArray(max) { it.toByte() }.also { it[0] = 0x65 }
        val single = RtpPacketizer(96).h264(listOf(fits), 0L, max)
        assertEquals(1, single.size)
        assertEquals(12 + max, single[0].size)
        assertArrayEquals(fits, depacketize(single).nals[0])

        val over = ByteArray(max + 1) { it.toByte() }.also { it[0] = 0x65 }
        val fragments = RtpPacketizer(96).h264(listOf(over), 0L, max)
        assertEquals(2, fragments.size)
        for (b in fragments) assertTrue(b.size <= 12 + max)
        assertEquals(28, fragments[0][12].toInt() and 0x1F)          // FU-A
        assertEquals(0x85, fragments[0][13].toInt() and 0xFF)        // The start bit, type 5.
        assertEquals(0x45, fragments[1][13].toInt() and 0xFF)        // The end bit, type 5.
        assertArrayEquals(over, depacketize(fragments).nals[0])
    }

    @Test
    fun skipsEmptyNals() {
        val packets = RtpPacketizer(96).h264(listOf(ByteArray(0), bytes(0x65, 1)), 0L)
        assertEquals(1, packets.size)
    }

    // MARK: Interleaved and Annex B

    @Test
    fun interleavedFrame() {
        val packet = ByteArray(300) { it.toByte() }
        val b = interleaved(packet, 2)
        assertEquals(304, b.size)
        assertEquals(0x24, b[0].toInt())                 // "$"
        assertEquals(2, b[1].toInt())
        assertEquals(0x01, b[2].toInt() and 0xFF)        // 300 = 0x012C, big-endian.
        assertEquals(0x2C, b[3].toInt() and 0xFF)
        assertArrayEquals(packet, b.copyOfRange(4, b.size))
    }

    @Test
    fun splitsAnnexB() {
        val stream = bytes(0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5)
        val nals = splitAnnexB(stream, 0, stream.size)
        assertEquals(3, nals.size)
        assertArrayEquals(bytes(0x67, 1, 2), nals[0])
        assertArrayEquals(bytes(0x68, 3), nals[1])      // The zero before a 4-byte start code is not in the NAL.
        assertArrayEquals(bytes(0x65, 4, 5), nals[2])
    }

    @Test
    fun splitsAnnexBInsideABuffer() {
        val stream = bytes(9, 9, 0, 0, 1, 0x41, 7, 0, 0, 0, 1, 0x41, 8, 9)
        val nals = splitAnnexB(stream, 2, stream.size - 3)
        assertEquals(2, nals.size)
        assertArrayEquals(bytes(0x41, 7), nals[0])
        assertArrayEquals(bytes(0x41, 8), nals[1])      // The last byte is outside the range.
    }

    @Test
    fun annexBWithNoStartCode() {
        assertEquals(0, splitAnnexB(bytes(0x65, 1, 2), 0, 3).size)
        assertEquals(0, splitAnnexB(ByteArray(0), 0, 0).size)
        // Bytes before the first start code are dropped.
        val nals = splitAnnexB(bytes(0x65, 1, 0, 0, 1, 0x41, 2), 0, 7)
        assertEquals(1, nals.size)
        assertArrayEquals(bytes(0x41, 2), nals[0])
    }

    // MARK: Helpers

    private fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    private fun sized(nal: ByteArray) = bytes(nal.size shr 8, nal.size and 0xFF) + nal

    private fun payload(p: RtpPacket) = p.data.copyOfRange(p.offset, p.offset + p.length)

    private fun raw(payload: ByteArray, seq: Int, ts: Long = 1000L, marker: Boolean = false, pt: Int = 96): ByteArray {
        val b = ByteArray(12 + payload.size)
        b[0] = 0x80.toByte()
        b[1] = ((if (marker) 0x80 else 0) or pt).toByte()
        b[2] = (seq shr 8).toByte(); b[3] = seq.toByte()
        for (i in 0..3) b[4 + i] = (ts shr (24 - 8 * i)).toByte()
        for (i in 0..3) b[8 + i] = (0x12345678 shr (24 - 8 * i)).toByte()
        payload.copyInto(b, 12)
        return b
    }

    private fun rtp(payload: ByteArray, seq: Int, ts: Long = 1000L, marker: Boolean = false) =
        RtpPacket.parse(raw(payload, seq, ts, marker))!!

    private fun depacketize(packets: List<ByteArray>): AccessUnit {
        val d = H264Depacketizer()
        var au: AccessUnit? = null
        for (b in packets) au = d.push(RtpPacket.parse(b)!!) ?: au
        return au!!
    }
}
