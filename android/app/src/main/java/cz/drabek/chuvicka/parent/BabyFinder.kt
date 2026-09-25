package cz.drabek.chuvicka.parent

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import cz.drabek.chuvicka.App
import cz.drabek.chuvicka.Log
import cz.drabek.chuvicka.proto.BABY_SERVICE_TYPE
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * It finds the phones at the baby with mDNS (NsdManager). An iPhone announces the same type
 * with Bonjour, so an Android parent finds an iPhone at the baby, and the other way round.
 */
class BabyFinder(context: Context) {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val _names = MutableStateFlow<List<String>>(emptyList())
    val names: StateFlow<List<String>> = _names
    private var listener: NsdManager.DiscoveryListener? = null

    fun start() {
        if (listener != null) return
        if (App.demo) { _names.value = listOf("Pokojíček"); return }
        val l = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(s: NsdServiceInfo) { _names.value = (_names.value + s.serviceName).distinct().sorted() }
            override fun onServiceLost(s: NsdServiceInfo) { _names.value = _names.value - s.serviceName }
            override fun onDiscoveryStarted(type: String) {}
            override fun onDiscoveryStopped(type: String) {}
            override fun onStartDiscoveryFailed(type: String, code: Int) { Log.add("discovery failed: $code") }
            override fun onStopDiscoveryFailed(type: String, code: Int) {}
        }
        listener = l
        nsd.discoverServices(BABY_SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
    }

    fun stop() {
        listener?.let { try { nsd.stopServiceDiscovery(it) } catch (_: Exception) {} }
        listener = null
    }

    companion object {
        /** The address of a phone at the baby, by its name. It blocks up to 6 s. */
        fun resolve(context: Context, name: String): Pair<String, Int>? {
            val nsd = context.getSystemService(NsdManager::class.java)
            val found = ArrayBlockingQueue<NsdServiceInfo>(1)
            val discovery = object : NsdManager.DiscoveryListener {
                override fun onServiceFound(s: NsdServiceInfo) { if (s.serviceName == name) found.offer(s) }
                override fun onServiceLost(s: NsdServiceInfo) {}
                override fun onDiscoveryStarted(type: String) {}
                override fun onDiscoveryStopped(type: String) {}
                override fun onStartDiscoveryFailed(type: String, code: Int) {}
                override fun onStopDiscoveryFailed(type: String, code: Int) {}
            }
            nsd.discoverServices(BABY_SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discovery)
            val service = found.poll(6, TimeUnit.SECONDS)
            try { nsd.stopServiceDiscovery(discovery) } catch (_: Exception) {}
            service ?: return null

            val resolved = ArrayBlockingQueue<Any>(1)
            @Suppress("DEPRECATION")      // The new callback API needs Android 14. This one works on all.
            nsd.resolveService(service, object : NsdManager.ResolveListener {
                override fun onServiceResolved(s: NsdServiceInfo) { resolved.offer(s) }
                override fun onResolveFailed(s: NsdServiceInfo, code: Int) { resolved.offer(code) }
            })
            val r = resolved.poll(6, TimeUnit.SECONDS) as? NsdServiceInfo ?: return null
            @Suppress("DEPRECATION")
            val host = r.host?.hostAddress ?: return null
            return host.substringBefore('%') to r.port
        }
    }
}
