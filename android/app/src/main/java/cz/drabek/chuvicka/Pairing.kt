package cz.drabek.chuvicka

import android.net.Uri
import cz.drabek.chuvicka.proto.RtspClient
import kotlinx.coroutines.flow.MutableStateFlow
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * The pairing link in the QR code of the phone at the baby. The iOS app makes and reads the same:
 * chuvicka://pair?n=<name>&c=<6 digits>&a=<"ip:port,ip:port", the Tailscale address first>
 */
object PairLink {
    class Info(val name: String, val code: String, val addresses: List<String>)

    fun build(name: String, code: String, addresses: List<String>): String =
        "chuvicka://pair?n=${Settings.encode(name)}&c=$code&a=${Settings.encode(addresses.joinToString(","))}"

    fun parse(uri: Uri?): Info? {
        if (uri == null || uri.scheme?.lowercase() != "chuvicka" || uri.host?.lowercase() != "pair") return null
        return try {
            val name = uri.getQueryParameter("n")?.trim() ?: return null
            val code = uri.getQueryParameter("c")?.trim() ?: return null
            if (name.isEmpty() || code.length != 6 || !code.all(Char::isDigit)) return null
            val addresses = (uri.getQueryParameter("a") ?: "").split(",").map { it.trim() }.filter { it.isNotEmpty() }
            Info(name, code, addresses)
        } catch (e: Exception) {
            null            // Not a hierarchical URI, or bad encoding.
        }
    }

    fun parse(text: String): Info? = try { parse(Uri.parse(text.trim())) } catch (e: Exception) { null }

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
