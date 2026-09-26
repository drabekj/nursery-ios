package cz.drabek.chuvicka.proto

import java.io.BufferedInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import java.net.URLDecoder
import java.security.MessageDigest
import kotlin.random.Random

/**
 * A small RTSP client: RTP interleaved over the one TCP connection. The same as the RTSPClient
 * of the iOS app. It reads go2rtc on the Pi, or the phone at the baby.
 *
 * The handshake runs on the caller's thread. After PLAY, [run] reads the packets until the
 * connection ends. A keepalive thread sends OPTIONS.
 *
 * An IP camera wants a user and a password: Digest (or Basic) authentication after a 401.
 */
class RtspClient(url: String, private val host: String, private val port: Int,
                 private val user: String = "", private val password: String = "") {
    class Failure(message: String) : IOException(message)

    class Track(val sdp: SdpTrack, val channel: Int)

    /** The host, the port, and the login of an RTSP URL. */
    data class Endpoint(val host: String, val port: Int, val user: String, val password: String)

    /** The URL without "user:pass@": the credentials go only in the Authorization header. */
    private val url = withoutCredentials(url)
    private val babyPhone = this.url.startsWith("rtsp://chuvicka/")
    private var socket: Socket? = null
    /** The last challenge of the server: "realm", "nonce", "qop", "opaque", or null for Basic. */
    private var digest: Map<String, String>? = null
    private var basic = false
    private var nonceCount = 0
    private lateinit var input: InputStream
    private lateinit var output: OutputStream
    private var cseq = 0
    private var session: String? = null
    @Volatile private var closed = false
    /** The addresses that the phone at the baby reported in DESCRIBE, for the time away from home. */
    var serverAddresses: List<String> = emptyList(); private set

    /** It connects, reads the SDP, and sets up the usable tracks. Then call [play]. */
    fun start(): List<Track> {
        val s = Socket()
        s.tcpNoDelay = true
        s.keepAlive = true
        s.connect(InetSocketAddress(host, port), 5000)
        s.soTimeout = 8000               // No data for 8 s: the connection is dead.
        socket = s
        input = BufferedInputStream(s.getInputStream(), 256 * 1024)
        output = s.getOutputStream()

        request("OPTIONS", url)
        val describe = request("DESCRIBE", url, mapOf("Accept" to "application/sdp"))
        val base = describe.headers["content-base"] ?: describe.headers["content-location"] ?: url
        val sdp = Sdp.parse(String(describe.body, Charsets.UTF_8))
        serverAddresses = describe.headers["x-chuvicka-addresses"]?.split(",")?.map { it.trim() }?.filter { it.isNotEmpty() } ?: emptyList()
        val tracks = ArrayList<Track>()
        for (t in sdp) {
            if (!isUsable(t) || tracks.any { it.sdp.kind == t.kind }) continue
            val channel = tracks.size * 2
            val setup = request("SETUP", Sdp.controlUrl(base, t.control),
                mapOf("Transport" to "RTP/AVP/TCP;unicast;interleaved=$channel-${channel + 1}"))
            if (session == null) session = setup.headers["session"]?.substringBefore(";")?.trim()
            tracks.add(Track(t, channel))
        }
        if (tracks.isEmpty()) throw Failure("Stream nemá video H.264 ani zvuk G.711.")
        return tracks
    }

    /** PLAY, then the packets, on this thread, until the connection ends. */
    fun play(onPacket: (channel: Int, packet: ByteArray) -> Unit) {
        request("PLAY", url, mapOf("Range" to "npt=0.000-"))
        val keepAlive = Thread {
            try {
                while (!closed) {
                    Thread.sleep(20_000)
                    if (!closed) send("OPTIONS", url, emptyMap())   // go2rtc accepts OPTIONS as a keepalive.
                }
            } catch (_: InterruptedException) {
            } catch (_: IOException) {
            }
        }.apply { isDaemon = true; name = "rtsp-keepalive"; start() }
        try {
            while (!closed) {
                val first = input.read()
                if (first < 0) throw Failure("Server ukončil spojení.")
                if (first == 0x24) {
                    val channel = readByte()
                    val length = (readByte() shl 8) or readByte()
                    val packet = readFully(length)
                    onPacket(channel, packet)
                } else if (first == 'R'.code) {
                    readResponse(first)              // The answer to a keepalive.
                }
            }
        } finally {
            keepAlive.interrupt()
            close()
        }
    }

    fun close() {
        if (closed) return
        closed = true
        try { socket?.close() } catch (_: IOException) {}
    }

    // MARK: The requests

    class Response(val status: Int, val reason: String, val headers: Map<String, String>, val body: ByteArray)

    private fun request(method: String, uri: String, headers: Map<String, String> = emptyMap()): Response {
        var retried = false
        while (true) {
            val r = answer(send(method, uri, headers))
            if (r.status == 401 && !retried && user.isNotEmpty() && !babyPhone) {
                val challenge = r.headers["www-authenticate"]
                if (challenge != null) { authenticate(challenge); retried = true; continue }
            }
            if (r.status == 401) throw Failure(when {
                babyPhone -> "Nesprávný párovací kód. Zadejte kód z telefonu u miminka."
                user.isEmpty() -> "Kamera chce uživatelské jméno a heslo."
                else -> "Kamera nepřijala uživatelské jméno nebo heslo."
            })
            if (r.status !in 200..299) throw Failure("Server odpověděl ${r.status} ${r.reason}.")
            return r
        }
    }

    private fun answer(id: Int): Response {
        while (true) {
            val first = input.read()
            if (first < 0) throw Failure("Server ukončil spojení.")
            if (first == 0x24) {                       // A packet before the answer: skip it.
                readByte(); val length = (readByte() shl 8) or readByte(); readFully(length)
                continue
            }
            val r = readResponse(first)
            if (r.headers["cseq"]?.toIntOrNull() == id) return r
        }
    }

    // MARK: The authentication (RFC 2617), as the IP cameras use it

    private fun authenticate(header: String) {
        if (Digest.isBasic(header)) { basic = true; digest = null; return }
        basic = false
        digest = Digest.parseChallenge(header)
        nonceCount = 0
    }

    private fun authorization(method: String, uri: String): String? {
        if (user.isEmpty()) return null
        if (basic) return Digest.basicHeader(user, password)
        val d = digest ?: return null
        val qop = Digest.chooseQop(d["qop"])
        var nc = ""
        var cnonce = ""
        if (qop != null) {
            nonceCount++
            nc = "%08x".format(nonceCount)
            cnonce = "%016x".format(Random.nextLong())
        }
        return Digest.header(user, password, method, uri, d["realm"] ?: "", d["nonce"] ?: "",
            qop, d["opaque"], d["algorithm"], nc, cnonce)
    }

    @Synchronized
    private fun send(method: String, uri: String, headers: Map<String, String>): Int {
        cseq++
        val text = StringBuilder("$method $uri RTSP/1.0\r\nCSeq: $cseq\r\nUser-Agent: Chuvicka-Android/1.0\r\n")
        session?.let { text.append("Session: $it\r\n") }
        authorization(method, uri)?.let { text.append("Authorization: $it\r\n") }
        for ((k, v) in headers) text.append("$k: $v\r\n")
        text.append("\r\n")
        output.write(text.toString().toByteArray(Charsets.UTF_8))
        output.flush()
        return cseq
    }

    private fun readResponse(firstByte: Int): Response {
        val head = StringBuilder().append(firstByte.toChar())
        while (!head.endsWith("\r\n\r\n")) {
            head.append(readByte().toChar())
            if (head.length > 16 * 1024) throw Failure("Chybná odpověď serveru.")
        }
        val lines = head.toString().trimEnd().split("\r\n")
        val status = lines[0].split(" ", limit = 3)
        val headers = HashMap<String, String>()
        for (line in lines.drop(1)) {
            val colon = line.indexOf(':')
            if (colon <= 0) continue
            val key = line.substring(0, colon).lowercase()
            // A camera may offer Basic and Digest: keep Digest.
            if (key == "www-authenticate" && headers[key]?.startsWith("Digest", ignoreCase = true) == true) continue
            headers[key] = line.substring(colon + 1).trim()
        }
        val body = readFully(headers["content-length"]?.toIntOrNull() ?: 0)
        return Response(status.getOrNull(1)?.toIntOrNull() ?: 0, status.getOrNull(2) ?: "", headers, body)
    }

    private fun readByte(): Int {
        val b = input.read()
        if (b < 0) throw Failure("Server ukončil spojení.")
        return b
    }

    private fun readFully(length: Int): ByteArray {
        val b = ByteArray(length)
        var n = 0
        while (n < length) {
            val r = input.read(b, n, length - n)
            if (r < 0) throw Failure("Server ukončil spojení.")
            n += r
        }
        return b
    }

    companion object {
        /** A quick TCP test: is this address here? Away from home the LAN address does not answer. */
        fun canConnect(host: String, port: Int, timeoutMs: Int = 1200): Boolean = try {
            Socket().use { it.connect(InetSocketAddress(host, port), timeoutMs) }
            true
        } catch (_: IOException) {
            false
        }

        /** Tailscale gives each device an address in 100.64.0.0/10. */
        fun isTailscale(host: String): Boolean {
            val p = host.split(".").mapNotNull { it.toIntOrNull() }
            return p.size == 4 && p[0] == 100 && p[1] in 64..127
        }

        fun isUsable(t: SdpTrack) =
            (t.kind == "video" && t.codec == "H264") || (t.kind == "audio" && (t.codec == "PCMA" || t.codec == "PCMU"))

        /** "rtsp://user:pass@192.168.0.10:8554/stream" to its host, port, user, and password. */
        fun parse(url: String): Endpoint {
            val u = try { URI(url) } catch (e: Exception) { throw Failure("Adresa kamery není platná.") }
            val info = u.rawUserInfo ?: ""
            val user = URLDecoder.decode(info.substringBefore(':'), "UTF-8")
            val password = if (':' in info) URLDecoder.decode(info.substringAfter(':'), "UTF-8") else ""
            return Endpoint(u.host ?: throw Failure("Adresa kamery není platná."), if (u.port > 0) u.port else 554, user, password)
        }

        fun forUrl(url: String): RtspClient {
            val e = parse(url)
            return RtspClient(url, e.host, e.port, e.user, e.password)
        }

        /** The URL without "user:pass@": the credentials go only in the Authorization header. */
        fun withoutCredentials(url: String): String =
            url.replaceFirst(Regex("^(rtsp://)[^/@]+@", RegexOption.IGNORE_CASE), "\$1")
    }
}

/** The authentication of the IP cameras (RFC 2617): pure functions, so the unit tests run them. */
object Digest {
    /** True when the camera asks for Basic, not Digest. */
    fun isBasic(header: String): Boolean = header.trim().startsWith("Basic", ignoreCase = true)

    /** The fields of a "Digest realm=..., nonce=..." challenge, the keys in lower case. */
    fun parseChallenge(header: String): Map<String, String> {
        val fields = HashMap<String, String>()
        for (m in Regex("(\\w+)=(?:\"([^\"]*)\"|([^,\\s]*))").findAll(header.substringAfter(' '))) {
            fields[m.groupValues[1].lowercase()] = m.groupValues[2].ifEmpty { m.groupValues[3] }
        }
        return fields
    }

    /** "auth" if the server offers it. The app does not do "auth-int". */
    fun chooseQop(offer: String?): String? = offer?.split(",")?.map { it.trim() }?.firstOrNull { it == "auth" }

    fun basicHeader(user: String, password: String): String =
        "Basic " + java.util.Base64.getEncoder().encodeToString("$user:$password".toByteArray(Charsets.UTF_8))

    /** The Authorization header. With no qop, nc and cnonce are not used. */
    fun header(user: String, password: String, method: String, uri: String, realm: String, nonce: String,
               qop: String?, opaque: String?, algorithm: String?, nc: String, cnonce: String): String {
        val ha1 = md5("$user:$realm:$password")
        val ha2 = md5("$method:$uri")
        val b = StringBuilder("Digest username=\"$user\", realm=\"$realm\", nonce=\"$nonce\", uri=\"$uri\"")
        if (qop != null) {
            b.append(", qop=$qop, nc=$nc, cnonce=\"$cnonce\", response=\"${md5("$ha1:$nonce:$nc:$cnonce:$qop:$ha2")}\"")
        } else {
            b.append(", response=\"${md5("$ha1:$nonce:$ha2")}\"")
        }
        opaque?.let { b.append(", opaque=\"$it\"") }
        algorithm?.let { b.append(", algorithm=$it") }
        return b.toString()
    }

    fun md5(text: String): String =
        MessageDigest.getInstance("MD5").digest(text.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
}
