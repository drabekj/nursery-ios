package cz.drabek.chuvicka.parent

import android.content.Context
import cz.drabek.chuvicka.Go2rtc
import cz.drabek.chuvicka.Log
import cz.drabek.chuvicka.Settings
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLDecoder

/**
 * Once, after the update: a phone that reads the camera through go2rtc switches to the camera
 * directly. go2rtc tells the camera's own RTSP URL (with its account) in /api/streams or /api/config.
 * The server settings stay, so the guide can go back to them. The same as ServerMigration on iOS.
 */
object ServerMigration {
    data class Result(
        val host: String, val port: Int, val user: String, val password: String,
        val mainPath: String, val smallPath: String?, val brand: Settings.CameraBrand,
    )

    private const val FLAG = "directMigrated"
    private const val TIMEOUT = 4000

    /**
     * Blocking (up to a few seconds, once): call it on Dispatchers.IO. True when it switched.
     * Runs only for a go2rtc camera and only once; the flag is set also when nothing was found.
     */
    fun run(context: Context): Boolean {
        val prefs = context.getSharedPreferences("migration", Context.MODE_PRIVATE)
        if (prefs.getBoolean(FLAG, false)) return false
        val host = Settings.host.value.trim()
        if (Settings.cameraKind.value != Settings.KIND_GO2RTC || Settings.source.value != Settings.Source.CAMERA || host.isEmpty()) {
            markDone(context)          // A new install or another source: never later.
            return false
        }
        val main = Settings.streamMain.value.trim()
        val small = Settings.streamSmall.value.trim()
        val found = try {
            get(host, "streams")?.let { parseStreams(it, main, small) }
                ?: get(host, "config")?.let { parseConfig(it, main, small) }
        } catch (e: IOException) {
            Log.add("migration: server not reached (${e.message})")
            null
        } catch (e: Exception) {
            Log.add("migration: ${e.javaClass.simpleName}")
            null
        }
        markDone(context)
        if (found == null) {
            Log.add("migration: no direct camera URL in go2rtc, keeping the server")
            return false
        }
        Settings.set(Settings.rtspUrl, "rtspUrl", "rtsp://${found.host}:${found.port}/${found.mainPath}")
        Settings.set(Settings.rtspUrlSmall, "rtspUrlSmall", found.smallPath?.let { "rtsp://${found.host}:${found.port}/$it" } ?: "")
        Settings.set(Settings.rtspUser, "rtspUser", found.user)
        Settings.rtspPassword = found.password
        Settings.set(Settings.rtspBrand, "rtspBrand", found.brand)
        Settings.set(Settings.cameraKind, "cameraKind", Settings.KIND_RTSP)
        Log.add("migrated to the direct camera ${found.host} (${found.brand.title})")
        return true
    }

    /** The guide chose the own server on purpose: never switch it away. */
    fun markDone(context: Context) {
        context.getSharedPreferences("migration", Context.MODE_PRIVATE).edit().putBoolean(FLAG, true).apply()
    }

    /** GET /api/<what>. Null on an answer other than 200; IOException when the server is not there. */
    private fun get(host: String, what: String): String? {
        val c = URL("http://$host:${Go2rtc.API_PORT}/api/$what").openConnection() as HttpURLConnection
        c.connectTimeout = TIMEOUT
        c.readTimeout = TIMEOUT
        try {
            if (c.responseCode != 200) return null
            return c.inputStream.use { it.readBytes() }.toString(Charsets.UTF_8)
        } finally {
            c.disconnect()
        }
    }

    // MARK: Pure: the unit tests run these. Two names, not two parse(): the same Kotlin signature.

    /** /api/streams: {"<name>":{"producers":[{"url":"rtsp://..."}, ...]}, ...}. */
    fun parseStreams(json: String, main: String, small: String): Result? {
        val parsed = try { MiniJson(json).value() } catch (_: Exception) { null }
        val root = parsed as? Map<*, *> ?: return null
        fun url(name: String): String? {
            val producers = (root[name] as? Map<*, *>)?.get("producers") as? List<*> ?: return null
            return producers.firstNotNullOfOrNull { p ->
                ((p as? Map<*, *>)?.get("url") as? String)?.takeIf { it.trim().startsWith("rtsp://", ignoreCase = true) }
            }
        }
        return result(url(main), url(small))
    }

    /** /api/config, the go2rtc YAML: "streams:" then "  <name>:" then "    - rtsp://...". */
    fun parseConfig(yaml: String, main: String, small: String): Result? {
        val lines = yaml.lines()
        val start = lines.indexOfFirst { it.trimEnd() == "streams:" }
        if (start < 0) return null
        // The block ends at the next line that is not indented.
        val block = lines.drop(start + 1).takeWhile { it.isBlank() || it.startsWith(" ") || it.startsWith("\t") || it.startsWith("#") }
        fun url(name: String): String? {
            val at = block.indexOfFirst { it.trim().startsWith("$name:") && indent(it) > 0 }
            if (at < 0) return null
            val own = indent(block[at])
            val inline = unquote(block[at].trim().removePrefix("$name:").substringBefore(" #").trim())
            if (inline.startsWith("rtsp://", ignoreCase = true)) return inline
            for (line in block.drop(at + 1)) {
                val t = line.trim()
                if (t.isEmpty() || t.startsWith("#")) continue
                if (indent(line) < own || (indent(line) == own && !t.startsWith("-"))) break      // The next stream.
                if (!t.startsWith("-")) continue
                val item = unquote(t.removePrefix("-").substringBefore(" #").trim())
                if (item.startsWith("rtsp://", ignoreCase = true)) return item
            }
            return null
        }
        return result(url(main), url(small))
    }

    /** The main stream's URL decides; the sub stream counts only on the same camera. */
    private fun result(mainUrl: String?, smallUrl: String?): Result? {
        val m = split(mainUrl ?: return null) ?: return null
        val s = smallUrl?.let(::split)?.takeIf { it.host == m.host && it.mainPath != m.mainPath }
        return m.copy(smallPath = s?.mainPath)
    }

    /**
     * "rtsp://user:pass@host:port/path?query#fragment" to its parts, the account percent-decoded.
     * By hand, not URI: a go2rtc config may hold a password with a raw "@" or "!".
     */
    private fun split(url: String): Result? {
        val text = url.trim().substringBefore('#')           // go2rtc options ("#backchannel=0").
        if (!text.startsWith("rtsp://", ignoreCase = true)) return null
        val rest = text.substring(7)
        val authority = rest.substringBefore('/')
        val path = rest.substringAfter('/', "")
        val info = authority.substringBeforeLast('@', "")
        val hostPort = authority.substringAfterLast('@')
        val host = hostPort.substringBefore(':')
        if (host.isEmpty()) return null
        val port = hostPort.substringAfter(':', "").toIntOrNull() ?: 554
        val user = decode(info.substringBefore(':'))
        val password = if (':' in info) decode(info.substringAfter(':')) else ""
        return Result(host, port, user, password, path, null, brand(path))
    }

    /** Percent-decoding that keeps "+" (it is a plus in a URL's account, not a space). */
    private fun decode(s: String): String = try {
        URLDecoder.decode(s.replace("+", "%2B"), "UTF-8")
    } catch (_: IllegalArgumentException) {
        s                                                   // A raw "%" in the password.
    }

    fun brand(path: String): Settings.CameraBrand {
        val p = path.lowercase()
        return when {
            p.startsWith("stream1") || p.startsWith("stream2") -> Settings.CameraBrand.TAPO
            p.startsWith("streaming/channels") -> Settings.CameraBrand.HIKVISION
            p.startsWith("cam/realmonitor") -> Settings.CameraBrand.DAHUA
            p.startsWith("h264preview") -> Settings.CameraBrand.REOLINK
            else -> Settings.CameraBrand.OTHER
        }
    }

    private fun indent(line: String) = line.length - line.trimStart().length

    private fun unquote(s: String): String =
        if (s.length >= 2 && (s[0] == '"' || s[0] == '\'') && s.last() == s[0]) s.substring(1, s.length - 1) else s
}

/**
 * A small JSON reader: objects to Map, arrays to List, strings, numbers as Double, true/false, null.
 * org.json is only a stub in the unit tests, so the parse above uses this.
 */
private class MiniJson(private val s: String) {
    private var i = 0

    fun value(): Any? {
        space()
        if (i >= s.length) throw IllegalArgumentException("end")
        return when (val c = s[i]) {
            '{' -> obj()
            '[' -> array()
            '"' -> string()
            't' -> word("true", true)
            'f' -> word("false", false)
            'n' -> word("null", null)
            else -> if (c == '-' || c.isDigit()) number() else throw IllegalArgumentException("at $i")
        }
    }

    private fun obj(): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>()
        i++
        space()
        if (peek() == '}') { i++; return out }
        while (true) {
            space()
            val key = string()
            space()
            expect(':')
            out[key] = value()
            space()
            when (next()) {
                ',' -> continue
                '}' -> return out
                else -> throw IllegalArgumentException("object at $i")
            }
        }
    }

    private fun array(): List<Any?> {
        val out = ArrayList<Any?>()
        i++
        space()
        if (peek() == ']') { i++; return out }
        while (true) {
            out.add(value())
            space()
            when (next()) {
                ',' -> continue
                ']' -> return out
                else -> throw IllegalArgumentException("array at $i")
            }
        }
    }

    private fun string(): String {
        expect('"')
        val b = StringBuilder()
        while (true) {
            val c = next()
            when (c) {
                '"' -> return b.toString()
                '\\' -> when (val e = next()) {
                    'n' -> b.append('\n')
                    't' -> b.append('\t')
                    'r' -> b.append('\r')
                    'b' -> b.append('\b')
                    'f' -> b.append('\u000C')
                    'u' -> {
                        if (i + 4 > s.length) throw IllegalArgumentException("escape")
                        b.append(s.substring(i, i + 4).toInt(16).toChar())
                        i += 4
                    }
                    else -> b.append(e)                // \" \\ \/
                }
                else -> b.append(c)
            }
        }
    }

    private fun number(): Double {
        val from = i
        while (i < s.length && (s[i].isDigit() || s[i] in "+-.eE")) i++
        return s.substring(from, i).toDouble()
    }

    private fun word(w: String, v: Any?): Any? {
        if (!s.startsWith(w, i)) throw IllegalArgumentException("at $i")
        i += w.length
        return v
    }

    private fun space() { while (i < s.length && s[i].isWhitespace()) i++ }
    private fun peek(): Char = if (i < s.length) s[i] else throw IllegalArgumentException("end")
    private fun next(): Char = if (i < s.length) s[i++] else throw IllegalArgumentException("end")
    private fun expect(c: Char) { if (next() != c) throw IllegalArgumentException("expected $c at $i") }
}
