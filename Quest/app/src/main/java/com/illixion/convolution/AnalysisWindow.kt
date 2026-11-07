package com.illixion.convolution

import java.net.URI
import java.net.URLDecoder

/*
 Rules for reading a Vergence coordinator's analysis track while a title
 plays, kept free of Android types so the JVM tests (src/test) run them:
 when to tell the coordinator where the playhead is, and which 10 s chunks
 to fetch. They follow the Vision Pro's `AnalysisPlayheadReporter` (Hypnos
 Services/AnalysisCoordinator.swift) and VergenceCore's
 `StreamingAnalysisTrack`.
 */

/**
 * When to report the playhead: every [intervalSeconds] while it plays (the
 * coordinator forgets a player after 20 s), and at once after a seek, which
 * is a playhead more than [seekSeconds] from where the last report says it
 * should be by now.
 */
internal class PlayheadRule(
    private val intervalSeconds: Double = 5.0,
    private val seekSeconds: Double = 3.0,
) {
    private var lastSeconds = Double.NaN
    private var lastAt = Double.NaN

    /** Starts from where playback opened (that report went out with the open). */
    fun start(seconds: Double, now: Double) { lastSeconds = seconds; lastAt = now }

    /** True when [seconds] at [now] (both seconds) should be reported; it then counts as sent. */
    fun due(seconds: Double, now: Double): Boolean {
        if (!lastAt.isNaN()) {
            val elapsed = now - lastAt
            val expected = lastSeconds + elapsed
            if (elapsed < intervalSeconds && Math.abs(seconds - expected) <= seekSeconds) return false
        }
        lastSeconds = seconds; lastAt = now
        return true
    }
}

/**
 * Which chunks to hold and fetch: the playhead's chunk, [lookAhead] after it
 * and one behind, nearest first, [concurrent] at a time. A partial chunk is
 * fetched again every [partialRefetchSeconds] until it comes whole; a failed
 * one (or one with nothing ready, a 404) after [retrySeconds]. Not thread
 * safe: the owner serialises calls.
 */
internal class ChunkWindow(
    val chunkSeconds: Double,
    val chunkCount: Int,
    val lookAhead: Int = 3,
    private val concurrent: Int = 2,
    private val retrySeconds: Double = 1.5,
    private val partialRefetchSeconds: Double = 1.5,
) {
    init { require(chunkSeconds > 0) { "chunks have a length" } }

    var playhead: Int? = null
        private set
    /** Held chunks: whole, or the time a partial one was fetched. */
    private val held = HashMap<Int, Double?>()
    private val inFlight = HashSet<Int>()
    private val failedAt = HashMap<Int, Double>()

    fun chunkAt(seconds: Double): Int = Math.max(0, Math.floor(seconds / chunkSeconds).toInt())

    /** The range of chunks to keep, while the playhead's chunk is [c]. */
    fun keepRange(c: Int): IntRange = (c - 1)..(c + lookAhead + 1)

    /**
     * The player asks about [seconds]. Returns the range to keep when the
     * playhead moved to another chunk (the store drops the rest), else null.
     */
    fun noteDemand(seconds: Double): IntRange? {
        val c = chunkAt(seconds)
        if (playhead == c) return null
        playhead = c
        val keep = keepRange(c)
        held.keys.retainAll { it in keep }
        return keep
    }

    /** Chunks to start fetching now, nearest the playhead first; they count as in flight. */
    fun next(now: Double): List<Int> {
        val c = playhead ?: return emptyList()
        val starting = ArrayList<Int>()
        for (n in c..(c + lookAhead)) {
            if (n >= chunkCount) break
            if (inFlight.size + starting.size >= concurrent) break
            if (n in inFlight) continue
            if (held.containsKey(n)) {
                val fetched = held[n] ?: continue  // whole: never again
                if (now - fetched < partialRefetchSeconds) continue
            }
            val failed = failedAt[n]
            if (failed != null && now - failed < retrySeconds) continue
            starting.add(n)
        }
        inFlight.addAll(starting)
        return starting
    }

    /** A fetch ended. Returns true when the chunk should be stored (it's still in the window). */
    fun finished(n: Int, success: Boolean, complete: Boolean, now: Double): Boolean {
        inFlight.remove(n)
        if (!success) { failedAt[n] = now; return false }
        failedAt.remove(n)
        val c = playhead ?: return false
        if (n !in keepRange(c)) return false
        held[n] = if (complete) null else now
        return true
    }

    /** The chunk holding [seconds] is here whole. */
    fun holdsWhole(seconds: Double): Boolean {
        val n = chunkAt(seconds)
        return held.containsKey(n) && held[n] == null
    }
}

/**
 * A pairing address link (`vergence://pair?mac=…&name=…&port=4869&addr=…`,
 * RAVECompanion's `RAVECompanionPairLink`), the hint the Vergence desktop
 * app shows for a device that can't find it over the network. It carries no
 * secret and grants nothing: the six-digit comparison still runs.
 */
internal data class PairLink(val hostId: String, val name: String, val port: Int, val addresses: List<String>) {
    companion object {
        const val SCHEME = "vergence"
        const val DEFAULT_PORT = 4869

        fun parse(text: String): PairLink? {
            val uri = try { URI(text.trim()) } catch (_: Exception) { return null }
            if (!uri.scheme.equals(SCHEME, ignoreCase = true) || uri.host != "pair") return null
            val query = uri.rawQuery ?: return null
            var id = ""; var name = ""; var port = DEFAULT_PORT
            val addresses = ArrayList<String>()
            for (part in query.split('&')) {
                val at = part.indexOf('=')
                if (at <= 0) continue
                val key = part.substring(0, at)
                val value = URLDecoder.decode(part.substring(at + 1).replace("+", "%2B"), "UTF-8")
                when (key) {
                    "mac" -> id = value
                    "name" -> name = value
                    "port" -> port = value.toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
                    "addr" -> if (value.isNotEmpty()) addresses.add(value)
                }
            }
            if (addresses.isEmpty()) return null
            return PairLink(id, name.ifEmpty { "Vergence" }, port, addresses)
        }
    }
}

/**
 * Where to pair, from what the person typed: a `vergence://pair` link, or an
 * address with an optional port (`192.168.1.20`, `pc.local:4869`,
 * `[fd00::5]:4869`, `fd00::5`), the port defaulting to the pairing port.
 */
internal fun pairTarget(text: String): Pair<String, Int>? {
    val value = text.trim()
    if (value.isEmpty()) return null
    PairLink.parse(value)?.let { return it.addresses.first() to it.port }
    if (value.contains("://") || value.contains('/') || value.contains(' ')) return null
    if (value.startsWith("[")) {
        val close = value.indexOf(']')
        if (close < 0) return null
        val host = value.substring(1, close)
        val rest = value.substring(close + 1)
        val port = if (rest.isEmpty()) PairLink.DEFAULT_PORT else rest.removePrefix(":").toIntOrNull() ?: return null
        return if (port in 1..65535 && host.isNotEmpty()) host to port else null
    }
    if (value.count { it == ':' } == 1) {
        val port = value.substringAfter(':').toIntOrNull() ?: return null
        val host = value.substringBefore(':')
        return if (port in 1..65535 && host.isNotEmpty()) host to port else null
    }
    return value to PairLink.DEFAULT_PORT  // a name, an IPv4 address, or a bare IPv6 address
}

/** The base URL a coordinator's HTTP API is reached at, from what the person typed. */
internal fun coordinatorBaseUrl(text: String, defaultPort: Int = 8420): String? {
    var value = text.trim().trimEnd('/')
    if (value.isEmpty()) return null
    if (!value.contains("://")) value = "http://$value"
    val uri = try { URI(value) } catch (_: Exception) { return null }
    if (uri.scheme != "http" && uri.scheme != "https") return null
    val host = uri.host ?: return null
    val port = if (uri.port > 0) uri.port else if (uri.scheme == "https") 443 else defaultPort
    val bracketed = if (host.contains(':') && !host.startsWith("[")) "[$host]" else host
    return "${uri.scheme}://$bracketed:$port"
}
