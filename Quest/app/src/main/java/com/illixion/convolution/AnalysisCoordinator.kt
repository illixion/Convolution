package com.illixion.convolution

import android.content.Context
import android.os.SystemClock
import android.util.Log
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "ConvolutionAnalysis"

/**
 * Where this Quest's Vergence analysis coordinator is (`vergenced`, or the
 * Vergence desktop app): the home server or a PC that hands a title's
 * analysis to worker machines and serves the results while they are made
 * (`docs/plans/analysis-workers.md`). Either paired by its six-digit code,
 * then reached over the paired TLS-PSK channel ([PairedChannelClient]), or set
 * by hand as an HTTP address and a bearer token, as the Vision Pro's Settings →
 * Analysis Server takes them. Secrets are sealed by the Keystore
 * ([SecureStore]); addresses and names sit in plain preferences.
 *
 * Not a data class: it holds a secret, and must never print one.
 */
class CoordinatorConfig(
    /** The HTTP API (set by hand), or null for a paired coordinator. */
    val baseUrl: String?,
    val bearer: String?,
    /** A paired coordinator's address and paired-channel port. */
    val pairedHost: String?,
    val pairedPort: Int,
    val pairingToken: String?,
    /** This Quest: the pairing's device id, and its player name at the coordinator. */
    val player: String,
    val hostName: String?,
) {
    val paired: Boolean get() = pairingToken != null
    override fun toString() = "CoordinatorConfig(paired=$paired)"
}

object AnalysisSettings {
    private const val PREFS = "analysis-coordinator"
    private const val SECRETS = "analysis-coordinator-secrets"
    const val DEFAULT_HTTP_PORT = 8420

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** This installation's id: the pairing's `headsetID` and the coordinator's player name. */
    fun deviceId(context: Context): String {
        val prefs = prefs(context)
        return prefs.getString("deviceId", null) ?: UUID.randomUUID().toString().also {
            prefs.edit().putString("deviceId", it).apply()
        }
    }

    fun smoothMotion(context: Context) = prefs(context).getBoolean("smoothMotion", true)
    fun setSmoothMotion(context: Context, on: Boolean) { prefs(context).edit().putBoolean("smoothMotion", on).apply() }

    /** AI HDR for 2D titles (the ai-hdr workload); it shows only on an HDR display. */
    fun aiHdr(context: Context) = prefs(context).getBoolean("aiHdr", true)
    fun setAiHdr(context: Context, on: Boolean) { prefs(context).edit().putBoolean("aiHdr", on).apply() }

    /** Whether the headset's display reports HDR (Quest 3's panels don't, as far as known: then AI HDR stays off). */
    fun displayIsHdr(context: Context): Boolean =
        context.getSystemService(android.hardware.display.DisplayManager::class.java)
            ?.getDisplay(android.view.Display.DEFAULT_DISPLAY)?.isHdr == true

    /** The configured coordinator, or null when there is none (or its secret can't be opened). Call off the main thread. */
    fun current(context: Context): CoordinatorConfig? {
        val prefs = prefs(context)
        val secrets = SecureStore(context, SECRETS)
        val device = deviceId(context)
        val host = prefs.getString("host", null)
        if (host != null) {
            val token = secrets.get("pairingToken") ?: return null
            return CoordinatorConfig(null, null, host, prefs.getInt("pairedPort", PairedChannelKeys.DEFAULT_PORT), token,
                device, prefs.getString("hostName", null))
        }
        val url = prefs.getString("baseUrl", null) ?: return null
        val token = secrets.get("token") ?: return null
        return CoordinatorConfig(url, token, null, 0, null, device, null)
    }

    /** What Settings shows, without opening any secret. */
    fun summary(context: Context): String? {
        val prefs = prefs(context)
        prefs.getString("host", null)?.let { host -> return "Paired with ${prefs.getString("hostName", "a computer")} · $host" }
        return prefs.getString("baseUrl", null)
    }

    fun isPaired(context: Context) = prefs(context).getString("host", null) != null

    /** The address field's starting text: a paired computer's address, or the HTTP server's. */
    fun address(context: Context): String = prefs(context).let { it.getString("host", null) ?: it.getString("baseUrl", "") ?: "" }

    fun savePaired(context: Context, host: String, hostId: String, hostName: String, addresses: List<String>, pairingToken: String) {
        SecureStore(context, SECRETS).apply { put("pairingToken", pairingToken); put("token", null) }
        prefs(context).edit().remove("baseUrl").putString("host", host).putInt("pairedPort", PairedChannelKeys.DEFAULT_PORT)
            .putString("hostId", hostId).putString("hostName", hostName)
            .putString("addresses", addresses.joinToString(" ")).apply()
    }

    fun saveManual(context: Context, baseUrl: String, token: String) {
        SecureStore(context, SECRETS).apply { put("token", token); put("pairingToken", null) }
        prefs(context).edit().putString("baseUrl", baseUrl)
            .remove("host").remove("pairedPort").remove("hostId").remove("hostName").remove("addresses").apply()
    }

    /** A paired computer moved (or is reached over a VPN now): keep the pairing, change its address. */
    fun setPairedHost(context: Context, host: String) { prefs(context).edit().putString("host", host).apply() }

    fun forget(context: Context) {
        SecureStore(context, SECRETS).apply { put("token", null); put("pairingToken", null) }
        prefs(context).edit().remove("baseUrl").remove("host").remove("pairedPort").remove("hostId").remove("hostName")
            .remove("addresses").apply()
    }
}

/**
 * The coordinator's API for a player (grant `play`), over the paired channel
 * or plain HTTP with a bearer token. Blocking: call off the main thread.
 */
class CoordinatorClient(private val config: CoordinatorConfig) {
    /** What the coordinator says about a title. */
    data class Status(val state: String, val chunkSeconds: Double, val chunks: Int, val frameRate: Double,
                      val piecesDone: Int, val pieces: Int)

    class HttpFailure(val status: Int) : Exception("HTTP $status")

    private val channel = if (config.paired) PairedChannelClient(config.pairedHost!!, config.pairedPort, config.player, config.pairingToken!!) else null

    private fun send(method: String, path: String, body: ByteArray? = null, contentType: String? = null): CoordinatorResponse {
        channel?.let { return it.request(method, path, body, contentType) }
        val connection = URL(config.baseUrl + path).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = method
            connection.connectTimeout = 5000
            connection.readTimeout = 15000
            connection.setRequestProperty("Authorization", "Bearer ${config.bearer}")
            if (body != null) {
                connection.doOutput = true
                contentType?.let { connection.setRequestProperty("Content-Type", it) }
                connection.outputStream.use { it.write(body) }
            }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val bytes = stream?.use { input -> ByteArrayOutputStream().also { input.copyTo(it) }.toByteArray() } ?: ByteArray(0)
            val headers = HashMap<String, String>()
            connection.headerFields.forEach { (name, values) -> if (name != null && values.isNotEmpty()) headers[name.lowercase()] = values.last() }
            return CoordinatorResponse(status, headers, bytes)
        } finally { connection.disconnect() }
    }

    private fun postPlaying(body: JSONObject) = send("POST", "/v1/playing", body.toString().toByteArray(Charsets.UTF_8), "application/json")

    /** The coordinator answers (no grant needed). */
    fun healthy(): Boolean = send("GET", "/v1/health").status == 200

    /**
     * The coordinator keeps one playhead per player name, so each workload a
     * title plays with reports as a player of its own.
     */
    private fun player(workload: String) = "${config.player}/$workload"

    /**
     * Says where this Quest is playing a Jellyfin item for [workload]: queues
     * the title and puts the pieces around [seconds] first. Throws for a title
     * the workload doesn't take (a 3D workload for a 2D title, a server it
     * doesn't know).
     */
    fun playing(itemId: String, seconds: Double, workload: String, rate: Double = 1.0): Status {
        val response = postPlaying(JSONObject().put("server", "jellyfin").put("id", itemId).put("workload", workload)
            .put("seconds", Math.max(seconds, 0.0)).put("rate", rate).put("player", player(workload)))
        if (response.status != 200) throw HttpFailure(response.status)
        val json = JSONObject(String(response.body, Charsets.UTF_8))
        return Status(json.optString("state"), json.optDouble("chunkSeconds", 0.0), json.optInt("chunks"),
            json.optDouble("frameRate", 0.0), json.optInt("piecesDone"), json.optInt("pieces"))
    }

    /** This Quest stopped playing with [workload]. */
    fun stopped(workload: String) {
        try {
            postPlaying(JSONObject().put("server", "jellyfin").put("id", "").put("seconds", 0)
                .put("player", player(workload)).put("stopped", true))
        } catch (_: Exception) { }
    }

    /** Chunk [index] of an item's [workload] track, whole or partial; null when none of it is ready (404). */
    fun chunk(itemId: String, index: Int, workload: String): Pair<ByteArray, Boolean>? {
        val id = URLEncoder.encode(itemId, "UTF-8")
        val response = send("GET", "/v1/titles/jellyfin/$id/$workload/chunks/$index")
        return when (response.status) {
            200 -> response.body to (response.headers["vergence-chunk-complete"] != "false")
            404 -> null
            else -> throw HttpFailure(response.status)
        }
    }

    fun close() { channel?.close() }

    companion object {
        /** Packed 3D titles: the left eye's flow and each frame's disparity. */
        const val SMOOTH_MOTION_3D = "smooth-motion-3d"
        /** 2D titles: the whole picture's flow pairs. */
        const val SMOOTH_MOTION_2D = "smooth-motion-2d"
        /** 2D titles played as AI 3D: each frame's depth. */
        const val AI_3D_DEPTH = "ai-3d-depth"
        /** 2D titles: each frame's AI HDR gain grid. */
        const val AI_HDR = "ai-hdr"
    }
}

/**
 * One title's track for one workload from the coordinator while it plays:
 * the chunks around the playhead in the native store, the playhead reported
 * as it moves. The renderer calls [noteDemand] for each new real frame, and
 * [fields], [depth] or [gainGrid] for what its pass needs; fetching runs on
 * its own threads.
 */
class AnalysisTrackStream private constructor(
    private val client: CoordinatorClient,
    private val itemId: String,
    val workload: String,
    val status: CoordinatorClient.Status,
    startSeconds: Double,
) {
    private val window = ChunkWindow(status.chunkSeconds, status.chunks)
    private val rule = PlayheadRule()
    private val io = Executors.newFixedThreadPool(3) { r -> Thread(r, "analysis-fetch").apply { isDaemon = true } }
    private val closed = AtomicBoolean(false)
    private val storeLock = Any()
    private var store = AnalysisNative.storeCreate(status.chunkSeconds)
    private var reporting = false
    private var misses = 0
    private var loggedFirst = false

    init {
        rule.start(startSeconds, now())
        noteDemand(startSeconds)
    }

    private fun now() = SystemClock.elapsedRealtime() / 1000.0

    /** The player is about to need [seconds] (media time): keep that window and fetch what's missing. */
    fun noteDemand(seconds: Double) {
        if (closed.get()) return
        val report: Boolean
        synchronized(window) {
            window.noteDemand(seconds)?.let { keep -> synchronized(storeLock) { AnalysisNative.storeRetain(store, keep.first, keep.last) } }
            report = !reporting && rule.due(seconds, now())
            if (report) reporting = true
        }
        if (report) io.execute {
            try { client.playing(itemId, seconds, workload) } catch (e: Exception) { Log.i(TAG, "playhead_report_failed error=${e.javaClass.simpleName}") }
            synchronized(window) { reporting = false }
        }
        schedule()
    }

    private fun schedule() {
        val starting = synchronized(window) { window.next(now()) }
        for (n in starting) io.execute { fetch(n) }
    }

    private fun fetch(n: Int) {
        var success = false; var complete = false; var bytes: ByteArray? = null
        try {
            val result = client.chunk(itemId, n, workload)
            if (result != null) { bytes = result.first; complete = result.second; success = true }
        } catch (e: Exception) {
            Log.i(TAG, "chunk_failed index=$n error=${e.javaClass.simpleName}")
        }
        if (closed.get()) return
        val keep = synchronized(window) { window.finished(n, success, complete, now()) }
        if (keep && bytes != null) {
            val error = synchronized(storeLock) { if (store != 0L) AnalysisNative.storePut(store, n, bytes, complete) else 0 }
            if (error != 0) Log.w(TAG, "chunk_unreadable index=$n error=$error")
            else if (!loggedFirst) { loggedFirst = true; Log.i(TAG, "first_chunk workload=$workload index=$n of=${status.chunks} complete=$complete") }
        }
        schedule()
    }

    private var flow: ByteBuffer = ByteBuffer.allocateDirect(0)
    private var mask: ByteBuffer = ByteBuffer.allocateDirect(0)
    private var disparity0: ByteBuffer = ByteBuffer.allocateDirect(0)
    private var disparity1: ByteBuffer = ByteBuffer.allocateDirect(0)
    private val dims = IntArray(4)

    /** Half-float fields for the real frames at [start] and [end]; the buffers are reused, read them before asking again. */
    class Fields(val flowWidth: Int, val flowHeight: Int, val flow: ByteBuffer, val mask: ByteBuffer,
                 val disparityWidth: Int, val disparityHeight: Int, val disparity0: ByteBuffer, val disparity1: ByteBuffer)

    /** Called on the GL thread only. */
    fun fields(start: Double, end: Double): Fields? {
        if (closed.get()) return null
        val needsDisparity = workload == CoordinatorClient.SMOOTH_MOTION_3D
        var result = synchronized(storeLock) { AnalysisNative.storeFields(store, start, end, flow, mask, disparity0, disparity1, dims, needsDisparity) }
        if (result == -1) {
            fun direct(bytes: Int) = ByteBuffer.allocateDirect(bytes).order(ByteOrder.nativeOrder())
            flow = direct(dims[0] * dims[1] * 8); mask = direct(dims[0] * dims[1] * 2)
            disparity0 = direct(dims[2] * dims[3] * 2); disparity1 = direct(dims[2] * dims[3] * 2)
            result = synchronized(storeLock) { AnalysisNative.storeFields(store, start, end, flow, mask, disparity0, disparity1, dims, needsDisparity) }
        }
        if (result != 1) {
            misses++
            val whole = synchronized(window) { window.holdsWhole(start) }
            if (whole && (misses == 1 || misses % 240 == 0)) {
                // A whole chunk without the pair: show how far the nearest is, as the Vision Pro does,
                // so a player clock that starts elsewhere than the track's shows up in the log.
                val offset = synchronized(storeLock) { AnalysisNative.storeNearestPairOffset(store, start) }
                Log.i(TAG, "fields_miss count=$misses nearest_pair_ms=${if (offset.isNaN()) "none" else "%+.1f".format(offset * 1000)}")
            }
            return null
        }
        for (b in listOf(flow, mask, disparity0, disparity1)) b.rewind()
        return Fields(dims[0], dims[1], flow, mask, dims[2], dims[3], disparity0, disparity1)
    }

    /** Half a frame at the title's rate: how near a depth map's or gain grid's time must be. */
    private val halfFrame = 0.5 / (if (status.frameRate > 1) status.frameRate else 24.0)

    /** A frame's depth map (ai-3d-depth); its bytes buffer is reused. */
    class Depth(val width: Int, val height: Int, val scale: Float, val offset: Float, val bytes: ByteBuffer)
    private var depthBytes: ByteBuffer = ByteBuffer.allocateDirect(0)
    private val depthInfo = IntArray(2)
    private val depthMapping = FloatArray(2)

    /** The depth map for the frame at [seconds], or null. GL thread only. */
    fun depth(seconds: Double): Depth? {
        if (closed.get()) return null
        noteDemand(seconds)
        var result = synchronized(storeLock) { AnalysisNative.storeDepth(store, seconds, halfFrame, depthBytes, depthInfo, depthMapping) }
        if (result == -1) {
            depthBytes = ByteBuffer.allocateDirect(depthInfo[0] * depthInfo[1])
            result = synchronized(storeLock) { AnalysisNative.storeDepth(store, seconds, halfFrame, depthBytes, depthInfo, depthMapping) }
        }
        if (result != 1) return null
        depthBytes.rewind()
        return Depth(depthInfo[0], depthInfo[1], depthMapping[0], depthMapping[1], depthBytes)
    }

    private val gridBytes: ByteBuffer = ByteBuffer.allocateDirect(16 * 9 * 8 * 2).order(ByteOrder.nativeOrder())

    /** The frame's gain grid (16x9x8 half floats) at [seconds], or null. GL thread only; the buffer is reused. */
    fun gainGrid(seconds: Double): ByteBuffer? {
        if (closed.get()) return null
        val found = synchronized(storeLock) { AnalysisNative.storeGainGrid(store, seconds, halfFrame, gridBytes) } == 1
        if (!found) return null
        gridBytes.rewind()
        return gridBytes
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        io.execute { client.stopped(workload); client.close() }
        io.shutdown()
        synchronized(storeLock) { AnalysisNative.storeDestroy(store); store = 0 }
    }

    companion object {
        /**
         * Asks the coordinator for [itemId] at [startSeconds]; null when there
         * is no coordinator or it won't work on the title. Blocking.
         */
        fun open(context: Context, itemId: String, startSeconds: Double, workload: String): AnalysisTrackStream? {
            val config = AnalysisSettings.current(context) ?: return null
            val client = CoordinatorClient(config)
            val status = try { client.playing(itemId, startSeconds, workload) } catch (e: Exception) {
                // Not a title it works on (2D, a disc), or the coordinator is away.
                Log.i(TAG, "no_coordinator_track workload=$workload error=${e.javaClass.simpleName}${(e as? CoordinatorClient.HttpFailure)?.let { " status=" + it.status } ?: ""}")
                return null
            }
            if (status.chunks <= 0 || status.chunkSeconds <= 0) return null
            Log.i(TAG, "coordinator_track workload=$workload state=${status.state} pieces=${status.piecesDone}/${status.pieces} chunks=${status.chunks} fps=${"%.3f".format(status.frameRate)}")
            return AnalysisTrackStream(client, itemId, workload, status, startSeconds)
        }
    }
}
