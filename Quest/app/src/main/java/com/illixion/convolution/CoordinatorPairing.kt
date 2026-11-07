package com.illixion.convolution

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.DataInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.SecureRandom
import java.util.concurrent.Executors

private const val TAG = "ConvolutionPairing"

/**
 * Finds Vergence computers on the network: the desktop app announces its
 * pairing listener as `_vergence-pair._tcp` while the person has asked to pair
 * (RAVECompanion's namespace service types: `_<stem>-pair._tcp`, stem
 * "vergence"), and its host record as `_vergence-mac._tcp`. Results come on
 * the main thread.
 */
internal class CoordinatorDiscovery(context: Context, private val onChange: (List<Found>) -> Unit) {
    data class Found(val name: String, val host: String, val port: Int, val pairing: Boolean)

    private val nsd = context.applicationContext.getSystemService(NsdManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val found = LinkedHashMap<String, Found>()
    private val listeners = ArrayList<NsdManager.DiscoveryListener>()
    private val resolver = Executors.newSingleThreadExecutor()

    fun start() {
        for (type in listOf("_vergence-pair._tcp", "_vergence-mac._tcp")) {
            val listener = object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(serviceType: String) {}
                override fun onDiscoveryStopped(serviceType: String) {}
                override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { Log.w(TAG, "discovery_failed code=$errorCode") }
                override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
                override fun onServiceFound(info: NsdServiceInfo) { resolve(info, type.startsWith("_vergence-pair")) }
                override fun onServiceLost(info: NsdServiceInfo) {
                    main.post { if (found.keys.removeAll { it.startsWith(info.serviceName + "|") }) onChange(found.values.toList()) }
                }
            }
            listeners.add(listener)
            try { nsd.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, listener) } catch (e: Exception) { Log.w(TAG, "discovery_unavailable") }
        }
    }

    @Suppress("DEPRECATION")
    private fun resolve(info: NsdServiceInfo, pairing: Boolean) {
        // resolveService takes one request at a time on older releases.
        resolver.execute {
            val done = java.util.concurrent.CountDownLatch(1)
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) { done.countDown() }
                override fun onServiceResolved(resolved: NsdServiceInfo) {
                    val address = if (Build.VERSION.SDK_INT >= 34) resolved.hostAddresses.firstOrNull() else resolved.host
                    val host = address?.hostAddress
                    if (host != null) main.post {
                        // Only the pairing listener's port is dialled; the host record's is a placeholder.
                        val port = if (pairing) resolved.port else PairLink.DEFAULT_PORT
                        found["${resolved.serviceName}|$pairing"] = Found(resolved.serviceName, host, port, pairing)
                        onChange(found.values.sortedByDescending { it.pairing }.distinctBy { it.name })
                    }
                    done.countDown()
                }
            })
            done.await(5, java.util.concurrent.TimeUnit.SECONDS)
        }
    }

    fun stop() {
        for (listener in listeners) try { nsd.stopServiceDiscovery(listener) } catch (_: Exception) { }
        listeners.clear()
        resolver.shutdownNow()
    }
}

/**
 * The Quest's half of RAVECompanion pairing with a Vergence coordinator, in
 * the headset's role (the same exchange Controller Bridge's PairingClient
 * runs against Longwave): commit, take the host's key, reveal, show the six
 * digits, wait for the person at the computer to press Pair, open the grant.
 * The maths is the vendored qcb_crypto (AnalysisNative) with Vergence's label.
 *
 * Messages are RAVEPairingMessage JSON ({"commit":{...}}), bytes as base64,
 * each behind a little-endian u32 length. One pairing at a time on its own
 * thread; the listener hears back on the main thread.
 */
internal class CoordinatorPairingClient {
    interface Listener {
        /** Show this: the computer shows the same six digits. */
        fun onCode(code: String, hostName: String)
        fun onPaired(result: Result)
        fun onFailed(message: String)
    }

    /** A pairing's outcome. [token] is the pairing token: keep it sealed, never log it. */
    class Result(val hostId: String, val hostName: String, val token: String, val addresses: List<String>, val grants: List<String>)

    private val main = Handler(Looper.getMainLooper())
    private val random = SecureRandom()
    @Volatile private var socket: Socket? = null
    @Volatile private var cancelled = false

    fun pair(address: String, port: Int, deviceId: String, deviceName: String, listener: Listener) {
        cancelled = false
        Thread({ run(address, port, deviceId, deviceName, listener) }, "pairing").apply { isDaemon = true }.start()
    }

    /** Stops waiting: the computer's prompt closes when the connection does. */
    fun cancel() {
        cancelled = true
        try { socket?.close() } catch (_: IOException) { }
    }

    private fun run(address: String, port: Int, deviceId: String, deviceName: String, listener: Listener) {
        val secret = ByteArray(32).also(random::nextBytes)
        val nonce = ByteArray(32).also(random::nextBytes)
        var agreed: ByteArray? = null
        try {
            Socket().use { s ->
                socket = s
                s.connect(InetSocketAddress(address, port), 5000)
                s.soTimeout = 30000
                val input = s.getInputStream(); val output = s.getOutputStream()
                val publicKey = AnalysisNative.pairPublicKey(secret) ?: throw IOException("no public key")
                write(output, JSONObject().put("commit", JSONObject()
                    .put("headsetID", deviceId).put("headsetName", deviceName)
                    .put("commitment", b64(AnalysisNative.pairCommitment(publicKey, nonce)))
                    .put("requested", JSONArray().put("play"))))

                val hello = read(input).getJSONObject("macHello")
                val hostId = hello.getString("macID")
                val hostName = hello.optString("macName", address)
                val hostPublic = unb64(hello.getString("publicKey"))
                val hostNonce = unb64(hello.getString("nonce"))
                if (hostPublic.size != 32 || hostNonce.size != 32) throw IOException("unexpected key sizes")

                write(output, JSONObject().put("reveal", JSONObject().put("publicKey", b64(publicKey)).put("nonce", b64(nonce))))
                agreed = AnalysisNative.pairAgree(secret, nonce, hostPublic, hostNonce) ?: throw IOException("the computer's key is unusable")
                val code = String(agreed!!, 0, 6, Charsets.US_ASCII)
                val key = agreed!!.copyOfRange(6, 38)
                main.post { listener.onCode(code, hostName) }

                // The person at the computer has this long to compare and answer.
                s.soTimeout = 300000
                val answer = read(input)
                if (answer.has("deny")) { fail(listener, "$hostName declined the pairing."); return }
                val sealed = unb64(answer.getJSONObject("accept").getString("sealedGrant"))
                val opened = AnalysisNative.boxOpen(key, sealed)
                key.fill(0)
                if (opened == null) throw IOException("the grant did not open")
                val grant = JSONObject(String(opened, Charsets.UTF_8))
                opened.fill(0)
                val grants = grant.optJSONArray("grants")?.let { a -> (0 until a.length()).map { a.optString(it) } } ?: emptyList()
                if ("play" !in grants) { fail(listener, "$hostName paired without permission to play. Allow it in Vergence's Devices list."); return }
                val addresses = ArrayList<String>().apply { add(address) }  // it answered here, so try it first
                grant.optJSONArray("addresses")?.let { listed ->
                    for (i in 0 until listed.length()) {
                        val a = listed.optString(i)
                        if (a.isNotEmpty() && a !in addresses) addresses.add(a)
                    }
                }
                val result = Result(grant.optString("macID", hostId), grant.optString("macName", hostName), grant.getString("token"), addresses, grants)
                main.post { listener.onPaired(result) }
            }
        } catch (e: Exception) {
            if (cancelled) fail(listener, "Pairing cancelled.")
            else {
                Log.w(TAG, "pairing_failed error=${e.javaClass.simpleName}")
                fail(listener, "Pairing didn't finish: ${e.message ?: e.javaClass.simpleName}")
            }
        } finally {
            socket = null
            secret.fill(0)
            agreed?.fill(0)
        }
    }

    private fun fail(listener: Listener, message: String) { main.post { listener.onFailed(message) } }

    private fun write(out: OutputStream, message: JSONObject) {
        val body = message.toString().toByteArray(Charsets.UTF_8)
        out.write(ByteBuffer.allocate(4 + body.size).order(ByteOrder.LITTLE_ENDIAN).putInt(body.size).put(body).array())
        out.flush()
    }

    private fun read(input: InputStream): JSONObject {
        val data = DataInputStream(input)
        val header = ByteArray(4).also(data::readFully)
        val length = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN).int
        if (length < 0 || length > 16 * 1024) throw IOException("pairing message too large")
        return JSONObject(String(ByteArray(length).also(data::readFully), Charsets.UTF_8))
    }

    private fun b64(data: ByteArray?): String = Base64.encodeToString(data ?: throw IOException("no data"), Base64.NO_WRAP)
    private fun unb64(text: String): ByteArray = Base64.decode(text, Base64.DEFAULT)
}
