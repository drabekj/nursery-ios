package cz.drabek.chuvicka

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class PairLinkTest {
    private val addresses = listOf("100.101.102.103:8555", "192.168.0.42:8555")

    @Test
    fun parsesALink() {
        val link = PairLink.parse("chuvicka://pair?n=Pokoj%C3%AD%C4%8Dek&c=482913&a=100.101.102.103:8555,192.168.0.42:8555")
        assertNotNull(link)
        assertEquals("Pokojíček", link!!.name)
        assertEquals("482913", link.code)
        assertEquals(addresses, link.addresses)
    }

    @Test
    fun parsesEncodedAddresses() {
        // build() encodes the comma and the colons too.
        val link = PairLink.parse("chuvicka://pair?n=Pokoj%C3%AD%C4%8Dek&c=482913&a=100.101.102.103%3A8555%2C192.168.0.42%3A8555")!!
        assertEquals(addresses, link.addresses)
    }

    @Test
    fun parsesAnIosLink() {
        // URLComponents on iOS: the name percent-encoded, a space as %20, ":" and "," as they are.
        val link = PairLink.parse("chuvicka://pair?n=D%C4%9Btsk%C3%BD%20pokoj&c=048213&a=100.101.102.103:8555,192.168.0.42:8555")!!
        assertEquals("Dětský pokoj", link.name)
        assertEquals("048213", link.code)        // A leading zero stays.
        assertEquals(addresses, link.addresses)
    }

    @Test
    fun buildThenParse() {
        val name = "Žofiin pokojíček & spol. = 100%"
        val text = PairLink.build(name, "007431", addresses)
        assertEquals(true, text.startsWith("chuvicka://pair?n="))
        val link = PairLink.parse(text)!!
        assertEquals(name, link.name)
        assertEquals("007431", link.code)
        assertEquals(addresses, link.addresses)
    }

    @Test
    fun buildEncodesASpaceAsPercent20() {
        // Not "+": the iOS app reads "+" as a plus.
        val text = PairLink.build("a b", "123456", listOf("1.2.3.4:8555"))
        assertEquals("chuvicka://pair?n=a%20b&c=123456&a=1.2.3.4%3A8555", text)
    }

    @Test
    fun noAddresses() {
        val link = PairLink.parse("chuvicka://pair?n=Pokoj&c=123456")!!
        assertEquals(emptyList<String>(), link.addresses)
        assertEquals(emptyList<String>(), PairLink.parse("chuvicka://pair?n=Pokoj&c=123456&a=")!!.addresses)
    }

    @Test
    fun trimsTheValues() {
        val link = PairLink.parse("  chuvicka://pair?n=%20Pokoj%20&c=%20123456&a=%20100.64.0.1:8555%20,,  \n")!!
        assertEquals("Pokoj", link.name)
        assertEquals("123456", link.code)
        assertEquals(listOf("100.64.0.1:8555"), link.addresses)
    }

    @Test
    fun theSchemeAndTheHostInAnyCase() {
        assertNotNull(PairLink.parse("CHUVICKA://PAIR?n=Pokoj&c=123456"))
        assertNotNull(PairLink.parse("chuvicka://pair/?n=Pokoj&c=123456"))
        assertNotNull(PairLink.parse("chuvicka://pair?n=Pokoj&c=123456#x"))
    }

    @Test
    fun theFirstValueWins() {
        assertEquals("A", PairLink.parse("chuvicka://pair?n=A&n=B&c=123456")!!.name)
    }

    @Test
    fun rejectsOtherLinks() {
        assertNull(PairLink.parse("https://pair?n=Pokoj&c=123456"))
        assertNull(PairLink.parse("chuvicka://other?n=Pokoj&c=123456"))
        assertNull(PairLink.parse("chuvicka://pairing?n=Pokoj&c=123456"))
        assertNull(PairLink.parse("chuvicka:pair?n=Pokoj&c=123456"))
        assertNull(PairLink.parse("Pokoj 123456"))
        assertNull(PairLink.parse(""))
    }

    @Test
    fun rejectsAMissingName() {
        assertNull(PairLink.parse("chuvicka://pair?c=123456&a=1.2.3.4:8555"))
        assertNull(PairLink.parse("chuvicka://pair?n=&c=123456"))
        assertNull(PairLink.parse("chuvicka://pair?n=%20%20&c=123456"))
    }

    @Test
    fun rejectsACodeOfOtherThanSixDigits() {
        assertNull(PairLink.parse("chuvicka://pair?n=Pokoj"))
        assertNull(PairLink.parse("chuvicka://pair?n=Pokoj&c=12345"))
        assertNull(PairLink.parse("chuvicka://pair?n=Pokoj&c=1234567"))
        assertNull(PairLink.parse("chuvicka://pair?n=Pokoj&c=12345a"))
        assertNull(PairLink.parse("chuvicka://pair?n=Pokoj&c=123%2056"))
    }

    @Test
    fun rejectsBadEncoding() {
        assertNull(PairLink.parse("chuvicka://pair?n=100%&c=123456"))
    }
}
