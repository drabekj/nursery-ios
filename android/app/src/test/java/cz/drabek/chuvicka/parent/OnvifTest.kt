package cz.drabek.chuvicka.parent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OnvifTest {
    // The shared vector of both apps (SPEC.md).
    private val nonce = "0123456789abcdef".toByteArray()
    private val created = "2026-09-26T20:00:00Z"

    @Test
    fun theSecurityHeader() {
        val h = Onvif.securityHeader("admin", "secret", nonce, created)
        assertTrue(h.contains("<wsse:Nonce>MDEyMzQ1Njc4OWFiY2RlZg==</wsse:Nonce>"))
        assertTrue(h.contains(">hM5GeUSvJCyVdAjYUQilpGW5Hhw=</wsse:Password>"))
        assertTrue(h.contains("<wsu:Created>2026-09-26T20:00:00Z</wsu:Created>"))
        assertTrue(h.contains("<wsse:Username>admin</wsse:Username>"))
        assertTrue(!h.contains("secret"))
    }

    @Test
    fun theEnvelope() {
        val e = Onvif.envelope(Onvif.getProfilesBody, "<x/>")
        assertTrue(e.startsWith("<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\">"))
        assertTrue(e.contains("<s:Header><x/></s:Header><s:Body><trt:GetProfiles"))
    }

    @Test
    fun theBodies() {
        val move = Onvif.continuousMoveBody("profile_1", -0.5f, 0f)
        assertTrue(move.contains("<tptz:ProfileToken>profile_1</tptz:ProfileToken>"))
        assertTrue(move.contains("x=\"-0.5\" y=\"0.0\""))
        assertTrue(Onvif.continuousMoveBody("p", 0f, 0.5f).contains("x=\"0.0\" y=\"0.5\""))
        val stop = Onvif.stopBody("profile_1")
        assertTrue(stop.contains("<tptz:PanTilt>true</tptz:PanTilt>"))
        assertTrue(stop.contains("<tptz:ProfileToken>profile_1</tptz:ProfileToken>"))
    }

    private val ptz = "<trt:Profiles fixed=\"true\" token=\"profile_1\"><tt:Name>mainStream</tt:Name>" +
        "<tt:PTZConfiguration token=\"ptz_conf\"><tt:Name>PTZ</tt:Name></tt:PTZConfiguration></trt:Profiles>"
    private val plain = "<trt:Profiles fixed=\"true\" token=\"profile_2\"><tt:Name>minorStream</tt:Name></trt:Profiles>"

    private fun answer(profiles: String) =
        "<s:Envelope><s:Body><trt:GetProfilesResponse>$profiles</trt:GetProfilesResponse></s:Body></s:Envelope>"

    @Test
    fun thePtzProfileFirst() {
        assertEquals("profile_1", Onvif.ptzProfileToken(answer(ptz + plain)))
    }

    @Test
    fun thePtzProfileSecond() {
        assertEquals("profile_1", Onvif.ptzProfileToken(answer(plain + ptz)))
    }

    @Test
    fun noPtzProfile() {
        assertNull(Onvif.ptzProfileToken(answer(plain)))
        assertNull(Onvif.ptzProfileToken(""))
    }

    @Test
    fun theCreatedTime() {
        assertTrue(Onvif.createdNow().matches(Regex("\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z")))
    }
}
