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
        val (own, prefix) = homeNetwork() ?: return@withContext emptyList()
        val hosts = (1..254).map { "$prefix.$it" }.filter { it != own }
        // At most 48 tries at a time: fast, and gentle with the router.
        val slots = Semaphore(48)
        val open = coroutineScope {
            hosts.map { h -> async { slots.withPermit { if (RtspClient.canConnect(h, port, 800)) h else null } } }.awaitAll()
        }.filterNotNull()
        open.sortedBy { it.substringAfterLast('.').toIntOrNull() ?: 0 }.map { h ->
            val answer = if (port == 554) rtspAnswer(h) else null
            Found(h, answer?.let(::brand), answer?.let(::label))
        }.also { Log.add("camera search on port $port: ${it.size} found") }
    }

    /** The Wi-Fi address and its first three parts ("192.168.0"). Wi-Fi first, else any private address. */
    fun homeNetwork(): Pair<String, String>? {
        var wifi: String? = null
        var other: String? = null
        val interfaces = try { NetworkInterface.getNetworkInterfaces()?.toList() } catch (_: Exception) { null } ?: return null
        for (i in interfaces) {
            if (!i.isUp || i.isLoopback) continue
            for (a in i.inetAddresses.toList()) {
                if (a !is Inet4Address) continue
                val ip = a.hostAddress ?: continue
                if (!isPrivate(ip)) continue
                if (i.name.startsWith("wlan")) wifi = ip else if (other == null) other = ip
            }
        }
        val ip = wifi ?: other ?: return null
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
