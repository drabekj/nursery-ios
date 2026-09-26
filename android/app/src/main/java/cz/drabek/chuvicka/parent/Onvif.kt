package cz.drabek.chuvicka.parent

import cz.drabek.chuvicka.Log
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.security.SecureRandom
import java.text.SimpleDateFormat
import java.util.Base64
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** The four ways to turn the camera. */
enum class PtzDirection { UP, DOWN, LEFT, RIGHT }

/**
 * ONVIF PTZ, the standard way to turn an IP camera: SOAP 1.2 over HTTP with a WS-Security login
 * (UsernameToken, PasswordDigest). Only what the app needs: GetProfiles, ContinuousMove, Stop.
 * Pure functions, no android.*, so the unit tests run them.
 */
object Onvif {
    private const val WSSE = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
    private const val WSU = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"
    private const val DIGEST_TYPE = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest"
    private const val PTZ_NS = "xmlns:tptz=\"http://www.onvif.org/ver20/ptz/wsdl\" xmlns:tt=\"http://www.onvif.org/ver10/schema\""

    /** The WS-Security header. Digest = Base64(SHA-1(nonce + created + password)). */
    fun securityHeader(user: String, password: String, nonce: ByteArray, created: String): String {
        val sha = MessageDigest.getInstance("SHA-1")
        sha.update(nonce)
        sha.update(created.toByteArray(Charsets.UTF_8))
        sha.update(password.toByteArray(Charsets.UTF_8))
        val digest = Base64.getEncoder().encodeToString(sha.digest())
        val nonce64 = Base64.getEncoder().encodeToString(nonce)
        return "<wsse:Security xmlns:wsse=\"$WSSE\" xmlns:wsu=\"$WSU\"><wsse:UsernameToken>" +
            "<wsse:Username>${xml(user)}</wsse:Username>" +
            "<wsse:Password Type=\"$DIGEST_TYPE\">$digest</wsse:Password>" +
            "<wsse:Nonce>$nonce64</wsse:Nonce><wsu:Created>$created</wsu:Created>" +
            "</wsse:UsernameToken></wsse:Security>"
    }

    fun envelope(body: String, security: String): String =
        "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\">" +
            "<s:Header>$security</s:Header><s:Body>$body</s:Body></s:Envelope>"

    const val getProfilesBody = "<trt:GetProfiles xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\"/>"

    fun continuousMoveBody(token: String, x: Float, y: Float): String =
        "<tptz:ContinuousMove $PTZ_NS><tptz:ProfileToken>${xml(token)}</tptz:ProfileToken>" +
            "<tptz:Velocity><tt:PanTilt x=\"${number(x)}\" y=\"${number(y)}\"/></tptz:Velocity></tptz:ContinuousMove>"

    fun stopBody(token: String): String =
        "<tptz:Stop $PTZ_NS><tptz:ProfileToken>${xml(token)}</tptz:ProfileToken>" +
            "<tptz:PanTilt>true</tptz:PanTilt></tptz:Stop>"

    private val profileRegex = Regex("<(?:\\w+:)?Profiles\\b([^>]*)>(.*?)</(?:\\w+:)?Profiles>", RegexOption.DOT_MATCHES_ALL)
    private val tokenRegex = Regex("\\btoken\\s*=\\s*[\"']([^\"']*)[\"']")

    /** The token of the first profile that can turn (it has a PTZConfiguration), from a GetProfiles answer. */
    fun ptzProfileToken(xml: String): String? {
        for (m in profileRegex.findAll(xml)) {
            if (!m.groupValues[2].contains("PTZConfiguration")) continue
            val token = tokenRegex.find(m.groupValues[1])?.groupValues?.get(1)
            if (!token.isNullOrEmpty()) return token
        }
        return null
    }

    /** The time for the login, in UTC. */
    fun createdNow(): String =
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(Date())

    private fun number(v: Float) = String.format(Locale.US, "%.1f", v)

    private fun xml(s: String) = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        .replace("\"", "&quot;").replace("'", "&apos;")
}

/**
 * The ONVIF connection to one camera. Blocking: call it on Dispatchers.IO or the monitor thread.
 * Same login as RTSP. It keeps the PTZ profile token in memory only.
 */
class OnvifClient(private val host: String, private val port: Int,
                  private val user: String, private val password: String) {
    @Volatile private var token: String? = null
    private val random = SecureRandom()

    /** The PTZ profile token, or null when the camera cannot turn (or does not answer). */
    fun loadPtzProfile(): String? {
        token?.let { return it }
        val (code, body) = post(Onvif.getProfilesBody) ?: return null
        if (code != 200) { Log.add("camera control: GetProfiles answered HTTP $code"); return null }
        val t = Onvif.ptzProfileToken(body)
        if (t == null) Log.add("camera control: no profile that can turn")
        token = t
        return t
    }

    fun move(x: Float, y: Float): Boolean {
        val t = loadPtzProfile() ?: return false
        return ok("ContinuousMove", post(Onvif.continuousMoveBody(t, x, y)))
    }

    fun stop(): Boolean {
        val t = loadPtzProfile() ?: return false
        return ok("Stop", post(Onvif.stopBody(t)))
    }

    /** One step: move, wait, stop. Stop also after a failed move, so the camera never keeps turning. */
    @Synchronized
    fun step(x: Float, y: Float, seconds: Float = 0.6f): Boolean {
        val moved = move(x, y)
        if (moved) {
            try { Thread.sleep((seconds * 1000).toLong()) } catch (_: InterruptedException) {}
        }
        val stopped = stop()
        return moved && stopped
    }

    private fun ok(what: String, answer: Pair<Int, String>?): Boolean {
        val code = answer?.first ?: return false
        if (code != 200) Log.add("camera control: $what answered HTTP $code")
        return code == 200
    }

    /** One SOAP request: the HTTP status and the body, or null when the camera does not answer. */
    private fun post(body: String): Pair<Int, String>? {
        val nonce = ByteArray(16).also { random.nextBytes(it) }
        val xml = Onvif.envelope(body, Onvif.securityHeader(user, password, nonce, Onvif.createdNow()))
        var c: HttpURLConnection? = null
        return try {
            c = URL("http://$host:$port/onvif/service").openConnection() as HttpURLConnection
            c.requestMethod = "POST"
            c.doOutput = true
            c.connectTimeout = 4000
            c.readTimeout = 4000
            c.setRequestProperty("Content-Type", "application/soap+xml; charset=utf-8")
            c.outputStream.use { it.write(xml.toByteArray(Charsets.UTF_8)) }
            val code = c.responseCode
            val stream = if (code in 200..299) c.inputStream else c.errorStream
            val text = stream?.use { String(it.readBytes(), Charsets.UTF_8) } ?: ""
            code to text
        } catch (e: IOException) {
            Log.add("camera control: $host:$port does not answer (${e.javaClass.simpleName})")
            null
        } finally {
            c?.disconnect()
        }
    }
}
