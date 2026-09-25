package cz.drabek.chuvicka.baby

import cz.drabek.chuvicka.Log
import cz.drabek.chuvicka.proto.RtpPacketizer
import cz.drabek.chuvicka.proto.interleaved
import java.io.BufferedInputStream
import java.io.IOException
import java.io.InputStream
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicLong
import kotlin.random.Random

/**
 * A small RTSP server on the phone at the baby. It speaks the same RTSP as go2rtc and as the
 * iOS app's BabyServer: RTP interleaved over TCP, H.264 video and G.711 A-law sound, and
 * `GET /<code>/frame.jpeg` for a photo. So an iPhone parent and an Android parent both read it.
 *
 * The pairing code is the first part of the path. A wrong code gets 401. After 10 wrong codes
 * in a minute, all requests fail for a minute.
 */
class BabyServer(
    private val code: String,
    private val hasVideo: Boolean,
    private val onClients: (all: Int, video: Int) -> Unit,
    private val onNeedKeyframe: () -> Unit,
    private val onFrameRequest: () -> ByteArray?,
) {
    private var server: ServerSocket? = null
    private val sessions = ConcurrentHashMap.newKeySet<Session>()
    @Volatile private var sps: ByteArray? = null
    @Volatile private var pps: ByteArray? = null
    private val wrongCodes = ArrayList<Long>()
    @Volatile private var running = false

    /** It opens a port that the system chooses, and returns it for the mDNS registration. */
    fun start(): Int {
        // A fixed port, so the address that a parent keeps for the time away stays valid.
        val s = try { ServerSocket(BABY_PORT) } catch (e: IOException) { ServerSocket(0) }
        server = s
        running = true
        Thread({
            while (running) {
                val socket = try { s.accept() } catch (e: IOException) { break }
                socket.tcpNoDelay = true
                val session = Session(socket)
                sessions.add(session)
                session.start()
            }
        }, "baby-accept").apply { isDaemon = true; start() }
        Log.add("baby server on port ${s.localPort}")
        return s.localPort
    }

    private val port get() = server?.localPort ?: BABY_PORT

    /** This phone's IPv4 addresses, the Tailscale one first. A parent keeps them for the time away. */
    private fun addresses(): String = cz.drabek.chuvicka.Net.ipv4().joinToString(", ") { "$it:$port" }

    fun stop() {
        running = false
        try { server?.close() } catch (_: IOException) {}
        sessions.forEach { it.close() }
        sessions.clear()
        report()
    }

    // MARK: The media

    fun sendVideo(nals: List<ByteArray>, timestamp: Long, keyframe: Boolean, sps: ByteArray?, pps: ByteArray?) {
        if (sps != null && pps != null) { this.sps = sps; this.pps = pps }
        val s = this.sps
        val p = this.pps
        // The parameter sets in the stream too: a parent that joins late needs no new DESCRIBE.
        val unit = if (keyframe && s != null && p != null) listOf(s, p) + nals else nals
        for (session in sessions) if (session.playing) session.sendVideo(unit, timestamp, keyframe)
    }

    /** 20 ms of A-law sound (160 bytes at 8 kHz). */
    fun sendAudio(aLaw: ByteArray, timestamp: Long) {
        for (session in sessions) if (session.playing) session.sendAudio(aLaw, timestamp)
    }

    private fun report() {
        val playing = sessions.filter { it.playing }
        onClients(playing.size, playing.count { it.takesVideo })
    }

    @Synchronized
    private fun authorized(uri: String): Boolean {
        val now = System.currentTimeMillis()
        wrongCodes.removeAll { now - it > 60_000 }
        if (wrongCodes.size >= 10) return false
        if (pathCode(uri) == code) return true
        wrongCodes.add(now)
        Log.add("baby server: a phone with a wrong code")
        return false
    }

    /** "rtsp://host/482913?audio/trackID=1" or "/482913/frame.jpeg" to "482913". */
    private fun pathCode(uri: String): String {
        val afterHost = if ("://" in uri) uri.substringAfter("://").let { r -> r.indexOf('/').let { if (it < 0) "" else r.substring(it) } } else uri
        return afterHost.split("/").firstOrNull { it.isNotEmpty() }?.substringBefore("?") ?: ""
    }

    private fun sdp(audioOnly: Boolean): String {
        val b = StringBuilder("v=0\r\no=- 0 0 IN IP4 0.0.0.0\r\ns=Chuvicka\r\nt=0 0\r\n")
        if (hasVideo && !audioOnly) {
            b.append("m=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n")
            var fmtp = "packetization-mode=1"
            val s = sps
            val p = pps
            if (s != null && p != null) {
                val enc = { x: ByteArray -> android.util.Base64.encodeToString(x, android.util.Base64.NO_WRAP) }
                fmtp += ";sprop-parameter-sets=${enc(s)},${enc(p)}"
            }
            b.append("a=fmtp:96 $fmtp\r\na=control:trackID=0\r\n")
        }
        b.append("m=audio 0 RTP/AVP 8\r\na=rtpmap:8 PCMA/8000\r\na=control:trackID=1\r\n")
        return b.toString()
    }

    /** One parent: a reader thread for the requests, and a writer thread with a bounded queue. */
    private inner class Session(private val socket: Socket) {
        @Volatile var playing = false
        @Volatile var videoChannel = -1
        @Volatile var audioChannel = -1
        val takesVideo get() = videoChannel >= 0
        private val sessionId = Random.nextInt(100_000, Int.MAX_VALUE).toString()
        private val video = RtpPacketizer(96)
        private val audio = RtpPacketizer(8)
        private val queue = LinkedBlockingQueue<ByteArray>()
        private val queued = AtomicLong(0)
        @Volatile private var waitForKeyframe = true
        @Volatile private var closed = false

        fun start() {
            Thread({ read() }, "baby-read").apply { isDaemon = true; start() }
            Thread({ write() }, "baby-write").apply { isDaemon = true; start() }
        }

        fun close() {
            if (closed) return
            closed = true
            val was = playing
            playing = false
            try { socket.close() } catch (_: IOException) {}
            queue.offer(ByteArray(0))              // It wakes the writer.
            sessions.remove(this)
            if (was) { Log.add("parent left"); report() }
        }

        // MARK: Sending

        @Synchronized
        fun sendVideo(nals: List<ByteArray>, timestamp: Long, keyframe: Boolean) {
            val channel = videoChannel
            if (channel < 0) return
            if (waitForKeyframe) {
                if (!keyframe) return
                waitForKeyframe = false
            }
            // More than about 1 s of picture waits: skip the picture until the next keyframe.
            if (queued.get() > 256 * 1024) {
                waitForKeyframe = true
                onNeedKeyframe()
                return
            }
            for (p in video.h264(nals, timestamp)) enqueue(interleaved(p, channel))
        }

        @Synchronized
        fun sendAudio(payload: ByteArray, timestamp: Long) {
            val channel = audioChannel
            if (channel < 0 || queued.get() > 512 * 1024) return
            enqueue(interleaved(audio.packet(payload, 0, payload.size, timestamp, false), channel))
        }

        private fun enqueue(bytes: ByteArray) {
            queued.addAndGet(bytes.size.toLong())
            queue.offer(bytes)
        }

        private fun write() {
            try {
                val out = socket.getOutputStream()
                while (!closed) {
                    val b = queue.take()
                    if (b.isEmpty()) continue
                    out.write(b)
                    queued.addAndGet(-b.size.toLong())
                    if (queue.isEmpty()) out.flush()
                }
            } catch (_: Exception) {
                close()
            }
        }

        // MARK: The requests

        private fun read() {
            try {
                val input = BufferedInputStream(socket.getInputStream())
                while (!closed) {
                    val first = input.read()
                    if (first < 0) break
                    if (first == 0x24) {                      // RTCP from the parent: skip it.
                        input.read(); val len = (input.read() shl 8) or input.read()
                        skip(input, len)
                        continue
                    }
                    val head = readHead(input, first) ?: break
                    val lines = head.split("\r\n")
                    val request = lines[0].split(" ")
                    val headers = HashMap<String, String>()
                    for (line in lines.drop(1)) {
                        val c = line.indexOf(':')
                        if (c > 0) headers[line.substring(0, c).lowercase()] = line.substring(c + 1).trim()
                    }
                    headers["content-length"]?.toIntOrNull()?.let { skip(input, it) }
                    if (request.size >= 3) handle(request[0], request[1], request[2], headers)
                }
            } catch (_: Exception) {
            }
            close()
        }

        /** InputStream.skipNBytes needs Android 13. This works on Android 8. */
        private fun skip(input: InputStream, n: Int) {
            var left = n
            while (left > 0) {
                if (input.read() < 0) return
                left--
            }
        }

        private fun readHead(input: InputStream, first: Int): String? {
            val b = StringBuilder().append(first.toChar())
            while (!b.endsWith("\r\n\r\n")) {
                val c = input.read()
                if (c < 0 || b.length > 16 * 1024) return null
                b.append(c.toChar())
            }
            return b.toString().trimEnd()
        }

        private fun handle(method: String, uri: String, version: String, headers: Map<String, String>) {
            val cseq = headers["cseq"] ?: "0"
            if (version.startsWith("HTTP")) {
                val jpeg = if (method == "GET" && uri.endsWith("/frame.jpeg") && authorized(uri)) onFrameRequest() else null
                if (jpeg != null) http("200 OK", "image/jpeg", jpeg) else http("401 Unauthorized", "text/plain", "no".toByteArray())
                close()
                return
            }
            if (method != "OPTIONS" && method != "GET_PARAMETER" && !authorized(uri)) {
                reply(401, "Unauthorized", cseq); return
            }
            when (method) {
                "OPTIONS" -> reply(200, "OK", cseq, mapOf("Public" to "OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN, GET_PARAMETER"))
                "GET_PARAMETER" -> reply(200, "OK", cseq, mapOf("Session" to sessionId))
                "DESCRIBE" -> reply(200, "OK", cseq,
                    mapOf("Content-Type" to "application/sdp", "X-Chuvicka-Addresses" to addresses()), sdp("?audio" in uri))
                "SETUP" -> {
                    val isVideo = "trackID=0" in uri
                    val transport = headers["transport"] ?: ""
                    val channel = Regex("interleaved=(\\d+)").find(transport)?.groupValues?.get(1)?.toIntOrNull()
                        ?: if (isVideo) 0 else 2
                    if (isVideo) videoChannel = channel else audioChannel = channel
                    reply(200, "OK", cseq, mapOf(
                        "Transport" to "RTP/AVP/TCP;unicast;interleaved=$channel-${channel + 1}",
                        "Session" to "$sessionId;timeout=60"))
                }
                "PLAY" -> {
                    reply(200, "OK", cseq, mapOf("Session" to sessionId, "Range" to "npt=0.000-"))
                    if (!playing) {
                        playing = true
                        waitForKeyframe = true
                        Log.add("parent connected")
                        report()
                        onNeedKeyframe()
                    }
                }
                "TEARDOWN" -> { reply(200, "OK", cseq, mapOf("Session" to sessionId)); close() }
                else -> reply(405, "Method Not Allowed", cseq)
            }
        }

        private fun reply(status: Int, reason: String, cseq: String, headers: Map<String, String> = emptyMap(), body: String = "") {
            val b = StringBuilder("RTSP/1.0 $status $reason\r\nCSeq: $cseq\r\nServer: Chuvicka\r\n")
            for ((k, v) in headers) b.append("$k: $v\r\n")
            val bytes = body.toByteArray(Charsets.UTF_8)
            if (bytes.isNotEmpty()) b.append("Content-Length: ${bytes.size}\r\n")
            b.append("\r\n")
            enqueue(b.toString().toByteArray(Charsets.UTF_8) + bytes)
        }

        private fun http(status: String, type: String, body: ByteArray) {
            val head = "HTTP/1.1 $status\r\nContent-Type: $type\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n"
            try {
                socket.getOutputStream().apply { write(head.toByteArray()); write(body); flush() }
            } catch (_: IOException) {}
        }
    }
}

/** The fixed port of the phone at the baby. The iOS app uses the same. */
const val BABY_PORT = 8555
