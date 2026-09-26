package cz.drabek.chuvicka.proto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DigestTest {
    // The example of RFC 2617, section 3.5.
    private val nonce = "dcd98b7102dd2f0e8b11d0f600bfb0c093"
    private val opaque = "5ccc069c403ebaf9f0171e9517f40e41"

    @Test
    fun theRfc2617Example() {
        val header = Digest.header("Mufasa", "Circle Of Life", "GET", "/dir/index.html",
            "testrealm@host.com", nonce, "auth", opaque, null, "00000001", "0a4f113b")
        assertEquals(
            "Digest username=\"Mufasa\", realm=\"testrealm@host.com\", nonce=\"$nonce\", uri=\"/dir/index.html\", " +
                "qop=auth, nc=00000001, cnonce=\"0a4f113b\", response=\"6629fae49393a05397450978507c4ef1\", " +
                "opaque=\"$opaque\"",
            header)
    }

    @Test
    fun noQop() {
        // RFC 2069: response = MD5(HA1:nonce:HA2), no nc and no cnonce.
        val header = Digest.header("Mufasa", "Circle Of Life", "GET", "/dir/index.html",
            "testrealm@host.com", nonce, null, null, "MD5", "", "")
        assertEquals(
            "Digest username=\"Mufasa\", realm=\"testrealm@host.com\", nonce=\"$nonce\", uri=\"/dir/index.html\", " +
                "response=\"670fd8c2df070c60b045671b8b24ff02\", algorithm=MD5",
            header)
    }

    @Test
    fun md5() {
        assertEquals("939e7578ed9e3c518a452acee763bce9", Digest.md5("Mufasa:testrealm@host.com:Circle Of Life"))
        assertEquals("39aff3a2bab6126f332b942af96d3366", Digest.md5("GET:/dir/index.html"))
    }

    @Test
    fun parsesAChallenge() {
        val fields = Digest.parseChallenge(
            "Digest realm=\"IP Camera(C1234)\", Nonce=\"a1b2, c3\", qop=\"auth,auth-int\", opaque=5ccc069c, stale=FALSE")
        assertEquals("IP Camera(C1234)", fields["realm"])      // A space inside the quotes.
        assertEquals("a1b2, c3", fields["nonce"])              // A comma inside the quotes, the key in lower case.
        assertEquals("auth,auth-int", fields["qop"])
        assertEquals("5ccc069c", fields["opaque"])             // Unquoted.
        assertEquals("FALSE", fields["stale"])
        assertNull(fields["algorithm"])
    }

    @Test
    fun parsesTheRfc2617Challenge() {
        val fields = Digest.parseChallenge(
            "Digest\n realm=\"testrealm@host.com\",\n qop=\"auth,auth-int\",\n nonce=\"$nonce\",\n opaque=\"$opaque\"")
        assertEquals("testrealm@host.com", fields["realm"])
        assertEquals(nonce, fields["nonce"])
        assertEquals(opaque, fields["opaque"])
    }

    @Test
    fun choosesQopAuth() {
        assertEquals("auth", Digest.chooseQop("auth"))
        assertEquals("auth", Digest.chooseQop("auth-int, auth"))
        assertNull(Digest.chooseQop("auth-int"))
        assertNull(Digest.chooseQop(null))
    }

    @Test
    fun basic() {
        assertTrue(Digest.isBasic("Basic realm=\"camera\""))
        assertTrue(Digest.isBasic("  basic realm=camera"))
        assertFalse(Digest.isBasic("Digest realm=\"camera\", nonce=\"1\""))
        // The example of RFC 7617.
        assertEquals("Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==", Digest.basicHeader("Aladdin", "open sesame"))
    }
}
