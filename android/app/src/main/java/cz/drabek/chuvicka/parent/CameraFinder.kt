package cz.drabek.chuvicka.parent

import cz.drabek.chuvicka.Log
import cz.drabek.chuvicka.Settings
import cz.drabek.chuvicka.proto.RtspClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket

/**
 * It finds cameras (and go2rtc servers) on the home Wi-Fi, so nobody has to look up an address.
 * The same way as the iOS app: a TCP test of one port on each address of the home network (/24),
 * 554 for IP cameras, 1984 for go2rtc. A camera that answers gets one RTSP request; its answer
 * (the Server header, or the realm of the login) often names the brand.
 */
object CameraFinder {
    data class Found(val host: String, val brand: Settings.CameraBrand?, val label: String?)

    /** All devices that answer on [port], in about 3 s. */
    suspend fun scan(port: Int): List<Found> = withContext(Dispatchers.IO) {
        openHosts(port).map { h ->
            val answer = if (port == 554) rtspAnswer(h) else null
            Found(h, answer?.let(::brand), answer?.let(::label))
        }.also { Log.add("camera search on port $port: ${it.size} found") }
    }

    /** The addresses of the home network (/24) that accept a TCP connection on [port], in order. */
    private suspend fun openHosts(port: Int): List<String> = withContext(Dispatchers.IO) {
        val (own, prefix) = homeNetwork() ?: return@withContext emptyList()
        val hosts = (1..254).map { "$prefix.$it" }.filter { it != own }
        // At most 48 tries at a time: fast, and gentle with the router.
        val slots = Semaphore(48)
        coroutineScope {
            hosts.map { h -> async { slots.withPermit { if (RtspClient.canConnect(h, port, 800)) h else null } } }.awaitAll()
        }.filterNotNull().sortedBy { it.substringAfterLast('.').toIntOrNull() ?: 0 }
    }

    /**
     * The saved camera no longer answers: it may have a new address from the router. Each device with
     * port 554 open gets one DESCRIBE with the saved account and the brand's main path; the first that
     * answers is the camera. Null when none answers, and for "Jiná kamera" (its path is unknown).
     */
    suspend fun relocate(): String? = withContext(Dispatchers.IO) {
        if (Settings.rtspBrand.value == Settings.CameraBrand.OTHER) return@withContext null
        val saved = Settings.rtspUrl.value.trim()
        if (saved.isEmpty()) return@withContext null
        val current = hostOf(saved)
        val url = Settings.withCredentials(saved, Settings.rtspUser.value, Settings.rtspPassword)
        for (h in openHosts(554).filter { it != current }) {
            val ok = try {
                RtspClient.forUrl(withHost(url, h)).describe()
                true
            } catch (_: Exception) {
                false
            }
            if (ok) {
                Log.add("camera search: found at $h")
                return@withContext h
            }
        }
        Log.add("camera search: not found")
        null
    }

    /** "rtsp://user:pass@192.168.0.5:554/stream1" with another host: "rtsp://user:pass@<host>:554/stream1". */
    fun withHost(url: String, host: String): String =
        Regex("^(rtsp://(?:[^@/]+@)?)[^:/]+", RegexOption.IGNORE_CASE).replace(url) { it.groupValues[1] + host }   // Anchored: one match.

    /** "rtsp://user:pass@192.168.0.50:554/stream1" to "192.168.0.50". */
    fun hostOf(url: String): String =
        url.substringAfter("://").substringBefore('/').substringAfterLast('@').substringBefore(':')

    /** The address of this phone in the home network and its first three parts ("192.168.0"). */
    fun homeNetwork(): Pair<String, String>? {
        val interfaces = try { NetworkInterface.getNetworkInterfaces()?.toList() } catch (_: Exception) { null } ?: return null
        val candidates = ArrayList<Pair<String, String>>()
        for (i in interfaces) {
            try {
                if (!i.isUp || i.isLoopback) continue
            } catch (_: Exception) {
                continue
            }
            for (a in i.inetAddresses.toList()) {
                if (a !is Inet4Address) continue
                val ip = a.hostAddress ?: continue
                candidates.add(i.name to ip)
            }
        }
        return pick(candidates)
    }

    /**
     * The home network among (interface name, IPv4 address): the Wi-Fi client first, then this phone's
     * own hotspot, then any other private address. Never the mobile data and never a VPN (Tailscale).
     * Returns (own address, prefix "192.168.0").
     */
    fun pick(candidates: List<Pair<String, String>>): Pair<String, String>? {
        val hotspots = setOf("ap0", "swlan0", "wlan1")
        val never = listOf("rmnet", "ccmni", "pdp", "tun", "tailscale")
        val usable = candidates.filter { (name, ip) -> isPrivate(ip) && never.none { name.startsWith(it) } }
        val ip = usable.firstOrNull { (name, _) -> name.startsWith("wlan") && name !in hotspots }?.second
            ?: usable.firstOrNull { (name, ip) -> name in hotspots || ip.startsWith("192.168.43.") || ip.startsWith("172.20.10.") }?.second
            ?: usable.firstOrNull()?.second
            ?: return null
        return ip to ip.split(".").take(3).joinToString(".")
    }

    /** 10/8, 172.16/12 and 192.168/16: the addresses of home networks. */
    fun isPrivate(ip: String): Boolean {
        val p = ip.split(".").mapNotNull { it.toIntOrNull() }
        if (p.size != 4) return false
        return p[0] == 10 || (p[0] == 172 && p[1] in 16..31) || (p[0] == 192 && p[1] == 168)
    }

    /** The brand in an RTSP answer, from its Server header or the realm of the login. */
    fun brand(answer: String): Settings.CameraBrand? {
        val a = answer.lowercase()
        return when {
            "tp-link" in a || "tapo" in a -> Settings.CameraBrand.TAPO
            "hikvision" in a -> Settings.CameraBrand.HIKVISION
            "dahua" in a || "login to" in a -> Settings.CameraBrand.DAHUA      // Dahua: realm="Login to <serial>".
            "reolink" in a -> Settings.CameraBrand.REOLINK
            else -> null
        }
    }

    /** A short name for the list: the brand, else the realm of the login, else the Server header. */
    fun label(answer: String): String? {
        brand(answer)?.let { return it.title }
        val lines = answer.split("\r\n")
        val realm = lines.firstOrNull { it.lowercase().startsWith("www-authenticate:") }
            ?.substringAfter("realm=\"", "")?.substringBefore('"')?.takeIf { it.isNotEmpty() }
        val server = lines.firstOrNull { it.lowercase().startsWith("server:") }
            ?.substring("server:".length)?.trim()?.takeIf { it.isNotEmpty() }
        return (realm ?: server)?.take(32)
    }

    /** One DESCRIBE with no login. Cameras answer 401 with the realm, or 200/404 with a Server header. */
    private fun rtspAnswer(host: String): String? = try {
        Socket().use { s ->
            s.connect(InetSocketAddress(host, 554), 1500)
            s.soTimeout = 1500
            s.getOutputStream().write("DESCRIBE rtsp://$host:554/ RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: Chuvicka\r\n\r\n".toByteArray())
            val buffer = ByteArray(4096)
            val n = s.getInputStream().read(buffer)
            if (n > 0) String(buffer, 0, n) else null
        }
    } catch (_: IOException) {
        null
    }
}
