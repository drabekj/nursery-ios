package cz.drabek.chuvicka

import android.net.Uri
import cz.drabek.chuvicka.proto.RtspClient
import kotlinx.coroutines.flow.MutableStateFlow
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.URLDecoder

/**
 * The pairing link in the QR code of the phone at the baby. The iOS app makes and reads the same:
 * chuvicka://pair?n=<name>&c=<6 digits>&a=<"ip:port,ip:port", the Tailscale address first>
 */
object PairLink {
    class Info(val name: String, val code: String, val addresses: List<String>)

    fun build(name: String, code: String, addresses: List<String>): String =
        "chuvicka://pair?n=${Settings.encode(name)}&c=$code&a=${Settings.encode(addresses.joinToString(","))}"

    fun parse(uri: Uri?): Info? = if (uri == null) null else parse(uri.toString())

    /** Plain Kotlin, not android.net.Uri, so the unit tests run it. */
    fun parse(text: String): Info? {
        val link = text.trim()
        val scheme = link.substringBefore("://", "")
        if (!scheme.equals("chuvicka", ignoreCase = true)) return null
        val rest = link.substring(scheme.length + 3).substringBefore('#')
        if (!rest.substringBefore('?').substringBefore('/').equals("pair", ignoreCase = true)) return null
        return try {
            val query = query(rest.substringAfter('?', ""))
            val name = query["n"]?.trim() ?: return null
            val code = query["c"]?.trim() ?: return null
            if (name.isEmpty() || code.length != 6 || !code.all(Char::isDigit)) return null
            val addresses = (query["a"] ?: "").split(",").map { it.trim() }.filter { it.isNotEmpty() }
            Info(name, code, addresses)
        } catch (e: Exception) {
            null            // Bad encoding.
        }
    }

    /** "n=a%20b&c=1" to its values, decoded. The first value of a key wins, as in Uri. */
    private fun query(text: String): Map<String, String> {
        val out = HashMap<String, String>()
        for (item in text.split('&')) {
            if (item.isEmpty()) continue
            val key = URLDecoder.decode(item.substringBefore('='), "UTF-8")
            if (key !in out) out[key] = URLDecoder.decode(item.substringAfter('=', ""), "UTF-8")
        }
        return out
    }

    /** It saves the pairing: this phone now watches that phone at the baby. */
    fun apply(pair: Info) {
        Settings.set(Settings.babyName, "babyName", pair.name)
        Settings.set(Settings.babyCode, "babyCode", pair.code)
        Settings.setBabyAddresses(pair.addresses)
        Settings.set(Settings.source, "source", Settings.Source.PHONE)
        Log.add("paired with ${pair.name} by the QR code")
    }
}

/** What the activity tells the wizard. */
object WizardEvents {
    /** A pairing link came from outside (the system camera): the wizard goes to the test. */
    val linkPaired = MutableStateFlow(false)
}

object Net {
    /** This phone's IPv4 addresses, the Tailscale one first. */
    fun ipv4(): List<String> = try {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.toList() }
            .filterIsInstance<Inet4Address>()
            .map { it.hostAddress ?: "" }
            .filter { it.isNotEmpty() && !it.startsWith("169.254.") }
            .distinct()
            .sortedByDescending { RtspClient.isTailscale(it) }
    } catch (e: Exception) {
        emptyList()
    }

    /** True when Tailscale runs on this phone: it has an address in 100.64.0.0/10. */
    fun hasTailscale(): Boolean = ipv4().any { RtspClient.isTailscale(it) }
}
