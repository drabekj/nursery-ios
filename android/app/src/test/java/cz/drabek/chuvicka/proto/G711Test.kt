package cz.drabek.chuvicka.proto

import org.junit.Assert.assertEquals
import org.junit.Test

class G711Test {
    // The reference decoders, written from the G.711 tables rather than from g711.c:
    // a sign bit, a 3-bit segment, and a 4-bit step, in the middle of its interval.

    /** A-law: the even bits inverted (0x55). Sign 1 is positive. 13-bit scale, times 8 for 16 bits. */
    private fun aLawReference(code: Int): Int {
        val a = code xor 0x55
        val segment = (a shr 4) and 0x07
        val step = a and 0x0F
        val magnitude = if (segment == 0) 2 * step + 1 else (2 * step + 33) shl (segment - 1)
        return if (a and 0x80 != 0) 8 * magnitude else -8 * magnitude
    }

    /** µ-law: all bits inverted. Sign 1 is negative. 14-bit scale with the bias 33, times 4 for 16 bits. */
    private fun uLawReference(code: Int): Int {
        val u = code.inv() and 0xFF
        val segment = (u shr 4) and 0x07
        val step = u and 0x0F
        val magnitude = ((2 * step + 33) shl segment) - 33
        return if (u and 0x80 != 0) -4 * magnitude else 4 * magnitude
    }

    @Test
    fun aLawMatchesTheReference() {
        for (code in 0..255) assertEquals("A-law $code", aLawReference(code), G711.aLaw[code].toInt())
    }

    @Test
    fun uLawMatchesTheReference() {
        for (code in 0..255) assertEquals("µ-law $code", uLawReference(code), G711.uLaw[code].toInt())
    }

    @Test
    fun knownValues() {
        assertEquals(8, G711.aLaw[0xD5].toInt())         // The smallest positive A-law step.
        assertEquals(-8, G711.aLaw[0x55].toInt())
        assertEquals(32256, G711.aLaw[0xAA].toInt())     // The loudest.
        assertEquals(-32256, G711.aLaw[0x2A].toInt())
        assertEquals(0, G711.uLaw[0xFF].toInt())         // µ-law has two zeros.
        assertEquals(0, G711.uLaw[0x7F].toInt())
        assertEquals(-32124, G711.uLaw[0x00].toInt())
        assertEquals(32124, G711.uLaw[0x80].toInt())
    }

    @Test
    fun aLawEncodeUndoesDecode() {
        for (code in 0..255) {
            assertEquals("A-law $code", code, G711.encodeALaw(G711.aLaw[code]).toInt() and 0xFF)
        }
    }

    @Test
    fun aLawEncodeClampsAndKeepsTheSign() {
        assertEquals(0xAA, G711.encodeALaw(Short.MAX_VALUE).toInt() and 0xFF)
        assertEquals(0x2A, G711.encodeALaw(Short.MIN_VALUE).toInt() and 0xFF)
        assertEquals(0xD5, G711.encodeALaw(0).toInt() and 0xFF)
        assertEquals(0x55, G711.encodeALaw((-1).toShort()).toInt() and 0xFF)
    }
}
