package com.illixion.convolution

import org.bouncycastle.tls.BasicTlsPSKIdentity
import org.bouncycastle.tls.CipherSuite
import org.bouncycastle.tls.PSKTlsClient
import org.bouncycastle.tls.ProtocolVersion
import org.bouncycastle.tls.TlsClientProtocol
import org.bouncycastle.tls.crypto.impl.bc.BcTlsCrypto
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/*
 The paired channel to a Vergence coordinator: its HTTP API over TLS 1.2 with
 an external PSK, keyed from the pairing token (vergence
 coordinator/src/paired.rs; docs/plans/analysis-workers.md, "The paired
 channel"):

 - port 8421 beside the HTTP port's 8420;
 - TLS 1.2 only, TLS_PSK_WITH_AES_128_GCM_SHA256 (0x00A8), no certificate;
 - PSK identity "VergenceAPI/v1/<device id>", the id this Quest paired with;
 - PSK = HKDF-SHA256(ikm: pairing token, salt: "Vergence-API-PSK-v1", info: "psk");
 - then plain HTTP/1.1, keep-alive, with no Authorization header: the
   handshake says who the device is, and its grants are what the person
   allowed when pairing.

 Bouncy Castle's TLS (bctls) because Android's own TLS (Conscrypt) offers no
 external-PSK client; Longwave's Windows Companion speaks the same suite with
 Bouncy Castle's C# port. No Android types here, so the JVM tests run it
 against a real coordinator.
 */

internal object PairedChannelKeys {
    const val IDENTITY_BASE = "VergenceAPI/v1"
    const val PSK_SALT = "Vergence-API-PSK-v1"
    const val DEFAULT_PORT = 8421

    fun identity(deviceId: String): ByteArray = "$IDENTITY_BASE/$deviceId".toByteArray(Charsets.UTF_8)

    fun psk(pairingToken: String): ByteArray =
        hkdfSha256(pairingToken.toByteArray(Charsets.UTF_8), PSK_SALT.toByteArray(Charsets.UTF_8), "psk".toByteArray(Charsets.UTF_8), 32)

    /** RFC 5869, for one block or a few. */
    fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(if (salt.isEmpty()) ByteArray(32) else salt, "HmacSHA256"))
        val prk = mac.doFinal(ikm)
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        val out = ByteArrayOutputStream()
        var block = ByteArray(0)
        var counter = 1
        while (out.size() < length) {
            mac.update(block); mac.update(info); mac.update(counter.toByte())
            block = mac.doFinal()
            out.write(block)
            counter++
        }
        prk.fill(0)
        return out.toByteArray().copyOf(length)
    }
}

/** One HTTP response: the status, headers (names lowercased) and the whole body. */
class CoordinatorResponse(val status: Int, val headers: Map<String, String>, val body: ByteArray)

/**
 * HTTP/1.1 requests to a coordinator over the paired channel, reusing a few
 * keep-alive connections. Thread safe: each request takes a connection of its
 * own. The pairing token stays in this object; it is never logged.
 */
class PairedChannelClient(
    private val host: String,
    private val port: Int,
    deviceId: String,
    pairingToken: String,
    private val connectTimeoutMs: Int = 5000,
    private val readTimeoutMs: Int = 15000,
) {
    private val identity = PairedChannelKeys.identity(deviceId)
    private val psk = PairedChannelKeys.psk(pairingToken)
    private val idle = ArrayDeque<Connection>()
    private val random = SecureRandom()

    private inner class Connection {
        val socket = Socket()
        val protocol: TlsClientProtocol
        val input: InputStream
        val output: OutputStream

        init {
            socket.tcpNoDelay = true
            socket.connect(InetSocketAddress(host, port), connectTimeoutMs)
            socket.soTimeout = readTimeoutMs
            protocol = TlsClientProtocol(socket.getInputStream(), socket.getOutputStream())
            try {
                protocol.connect(object : PSKTlsClient(BcTlsCrypto(random), BasicTlsPSKIdentity(identity, psk)) {
                    override fun getSupportedCipherSuites(): IntArray = intArrayOf(CipherSuite.TLS_PSK_WITH_AES_128_GCM_SHA256)
                    override fun getSupportedVersions(): Array<ProtocolVersion> = ProtocolVersion.TLSv12.only()
                })
            } catch (e: IOException) {
                try { socket.close() } catch (_: IOException) { }
                throw e
            }
            input = protocol.inputStream.buffered()
            output = protocol.outputStream
        }

        fun close() {
            try { protocol.close() } catch (_: IOException) { }
            try { socket.close() } catch (_: IOException) { }
        }
    }

    /** Sends one request; a stale keep-alive connection is retried once on a fresh one. */
    fun request(method: String, path: String, body: ByteArray? = null, contentType: String? = null): CoordinatorResponse {
        val reused = synchronized(idle) { idle.removeLastOrNull() }
        if (reused != null) {
            try { return exchange(reused, method, path, body, contentType) } catch (_: IOException) { reused.close() }
        }
        return exchange(Connection(), method, path, body, contentType)
    }

    private fun exchange(connection: Connection, method: String, path: String, body: ByteArray?, contentType: String?): CoordinatorResponse {
        val head = StringBuilder()
            .append(method).append(' ').append(path).append(" HTTP/1.1\r\n")
            .append("Host: ").append(if (host.contains(':')) "[$host]" else host).append(':').append(port).append("\r\n")
            .append("Connection: keep-alive\r\n")
        if (body != null) {
            head.append("Content-Length: ").append(body.size).append("\r\n")
            if (contentType != null) head.append("Content-Type: ").append(contentType).append("\r\n")
        }
        head.append("\r\n")
        connection.output.write(head.toString().toByteArray(Charsets.ISO_8859_1))
        if (body != null) connection.output.write(body)
        connection.output.flush()

        val statusLine = readLine(connection.input) ?: throw IOException("the connection closed")
        val parts = statusLine.split(' ', limit = 3)
        val status = parts.getOrNull(1)?.toIntOrNull() ?: throw IOException("not an HTTP response")
        val headers = HashMap<String, String>()
        while (true) {
            val line = readLine(connection.input) ?: throw IOException("headers cut short")
            if (line.isEmpty()) break
            val colon = line.indexOf(':')
            if (colon > 0) headers[line.substring(0, colon).trim().lowercase()] = line.substring(colon + 1).trim()
        }
        var reusable = headers["connection"]?.equals("close", ignoreCase = true) != true
        val content = when {
            status == 204 || status == 304 || status / 100 == 1 || method == "HEAD" -> ByteArray(0)
            headers["transfer-encoding"]?.contains("chunked", ignoreCase = true) == true -> readChunked(connection.input)
            headers["content-length"] != null -> readExactly(connection.input, headers["content-length"]!!.toLong())
            else -> { reusable = false; connection.input.readBytes() }
        }
        if (reusable) synchronized(idle) { if (idle.size < 4) idle.addLast(connection) else connection.close() } else connection.close()
        return CoordinatorResponse(status, headers, content)
    }

    fun close() {
        synchronized(idle) { while (idle.isNotEmpty()) idle.removeFirst().close() }
        psk.fill(0)
    }

    private fun readLine(input: InputStream): String? {
        val line = ByteArrayOutputStream()
        while (true) {
            val b = input.read()
            if (b < 0) return if (line.size() == 0) null else line.toString("ISO-8859-1")
            if (b == '\n'.code) break
            if (line.size() > 16 * 1024) throw IOException("header line too long")
            line.write(b)
        }
        return line.toString("ISO-8859-1").trimEnd('\r')
    }

    private fun readExactly(input: InputStream, length: Long): ByteArray {
        if (length < 0 || length > MAX_BODY) throw IOException("response too large")
        val out = ByteArray(length.toInt())
        var read = 0
        while (read < out.size) {
            val n = input.read(out, read, out.size - read)
            if (n < 0) throw IOException("body cut short")
            read += n
        }
        return out
    }

    private fun readChunked(input: InputStream): ByteArray {
        val out = ByteArrayOutputStream()
        while (true) {
            val size = (readLine(input) ?: throw IOException("chunk cut short")).substringBefore(';').trim().toLong(16)
            if (size == 0L) {
                while ((readLine(input) ?: "").isNotEmpty()) { }  // trailers
                return out.toByteArray()
            }
            if (out.size() + size > MAX_BODY) throw IOException("response too large")
            out.write(readExactly(input, size))
            readLine(input)
        }
    }

    private companion object {
        /** A 10 s chunk of a 4K title is a few tens of MB at most. */
        const val MAX_BODY = 256L shl 20
    }
}
