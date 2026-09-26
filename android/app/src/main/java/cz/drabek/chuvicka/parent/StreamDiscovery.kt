package cz.drabek.chuvicka.parent

import cz.drabek.chuvicka.Go2rtc
import cz.drabek.chuvicka.Log
import cz.drabek.chuvicka.Settings
import cz.drabek.chuvicka.proto.H264Depacketizer
import cz.drabek.chuvicka.proto.H264Sps
import cz.drabek.chuvicka.proto.RtpPacket
import cz.drabek.chuvicka.proto.RtspClient
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * The app learns the two go2rtc streams itself: it asks go2rtc for its streams and reads the
 * picture size of each. The biggest is the detail stream, the smallest the everyday stream.
 * Blocking, for up to a few seconds per stream: call it off the main thread.
 */
object StreamDiscovery {
    private const val TIMEOUT = 4000
    private const val MAX_STREAMS = 8

    fun run(host: String) {
        if (host.isEmpty()) return
        val names = try { streamNames(host) } catch (e: Exception) {
            Log.add("streams: no list from go2rtc (${e.message}), keeping ${Settings.streamMain.value}, ${Settings.streamSmall.value}")
            return
        }
        val sizes = names.take(MAX_STREAMS).mapNotNull { name -> size(host, name)?.let { name to it } }
        if (sizes.isEmpty()) {
            Log.add("streams: none with a readable H.264 picture (${names.joinToString()}), keeping ${Settings.streamMain.value}, ${Settings.streamSmall.value}")
            return
        }
        val big = sizes.maxBy { it.second.first * it.second.second }
        val small = sizes.minBy { it.second.first * it.second.second }
        // The same size twice is one stream for both: a switch would give nothing.
        val everyday = if (small.second.first * small.second.second == big.second.first * big.second.second) big else small
        Log.add("streams: ${sizes.joinToString { "${it.first} ${it.second.first}×${it.second.second}" }} → detail ${big.first}, everyday ${everyday.first}")
        Settings.set(Settings.streamMain, "streamMain", big.first)
        Settings.set(Settings.streamSmall, "streamSmall", everyday.first)
    }

    /** GET /api/streams: a JSON object, its keys are the stream names. */
    private fun streamNames(host: String): List<String> {
        val c = URL("http://$host:${Go2rtc.API_PORT}/api/streams").openConnection() as HttpURLConnection
        c.connectTimeout = TIMEOUT
        c.readTimeout = TIMEOUT
        try {
            if (c.responseCode != 200) throw java.io.IOException("HTTP ${c.responseCode}")
            val json = JSONObject(c.inputStream.use { it.readBytes() }.toString(Charsets.UTF_8))
            return json.keys().asSequence().filter { it.isNotBlank() && '/' !in it && ' ' !in it }.toList()
        } finally {
            c.disconnect()
        }
    }

    /** The picture size: from the SDP, else from the first SPS in the stream (at most about 3 s). */
    private fun size(host: String, name: String): Pair<Int, Int>? {
        val client = RtspClient("rtsp://$host:${Go2rtc.RTSP_PORT}/$name", host, Go2rtc.RTSP_PORT, timeoutMs = TIMEOUT)
        var found: Pair<Int, Int>? = null
        var timer: Thread? = null
        try {
            val video = client.start().firstOrNull { it.sdp.kind == "video" } ?: return null
            video.sdp.h264ParameterSets?.let { (sps, _) -> H264Sps.size(sps) }?.let { return it }
            timer = Thread {
                try { Thread.sleep(3000) } catch (_: InterruptedException) {}
                client.close()
            }.apply { isDaemon = true; start() }
            val depacketizer = H264Depacketizer()
            client.play { channel, bytes ->
                if (channel != video.channel) return@play
                depacketizer.push(RtpPacket.parse(bytes) ?: return@play)
                val sps = depacketizer.sps ?: return@play
                found = H264Sps.size(sps)
                client.close()
            }
        } catch (e: Exception) {
            if (found == null) Log.add("streams: $name not read (${e.message})")
        } finally {
            timer?.interrupt()
            client.close()
        }
        return found
    }
}
