package com.illixion.convolution

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.io.IOException

/**
 * The paired channel's keys against vergence-companion's (the Rust the
 * coordinator runs), and, when a coordinator is given, a real TLS-PSK
 * session with it:
 *
 *   VERGENCE_PAIRED_TEST=127.0.0.1:8421 VERGENCE_PAIRED_DEVICE=<device id>
 *   VERGENCE_PAIRED_TOKEN_FILE=<file holding that device's pairing token>
 *
 * with the device in the coordinator's devices.json granted `play`. Never a
 * real token in argv: the test reads it from the file and prints nothing of it.
 */
class PairedChannelTest {
    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }

    @Test fun keysMatchTheCoordinators() {
        // vergence-companion: Channel::new("VergenceAPI/v1", "Vergence-API-PSK-v1").derive("pairing-token")
        assertEquals("5775cf23a16574d3f1dbb10f464936525617f98db7804d92c8136d844d24d9f3", hex(PairedChannelKeys.psk("pairing-token")))
        assertArrayEquals("VergenceAPI/v1/HS-1".toByteArray(), PairedChannelKeys.identity("HS-1"))
        // desktop/src/pairing.rs http_token("pairing-token", "HS-1"), the same HKDF with another salt
        assertEquals("727ebcccd3a89bc400710d63faf0f26c0c41ffe8529a4df082890a7da53da575",
            hex(PairedChannelKeys.hkdfSha256("pairing-token".toByteArray(), "Vergence-HTTP-Token-v1".toByteArray(), "HS-1".toByteArray(), 32)))
        // RFC 5869 test case 1 (42 bytes: two blocks)
        val okm = PairedChannelKeys.hkdfSha256(ByteArray(22) { 0x0b }, ByteArray(13) { it.toByte() }, ByteArray(10) { (0xf0 + it).toByte() }, 42)
        assertEquals("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865", hex(okm))
    }

    @Test fun talksToARealCoordinatorOverTlsPsk() {
        val target = System.getenv("VERGENCE_PAIRED_TEST")
        val device = System.getenv("VERGENCE_PAIRED_DEVICE")
        val tokenFile = System.getenv("VERGENCE_PAIRED_TOKEN_FILE")
        assumeTrue("no coordinator given", target != null && device != null && tokenFile != null)
        val host = target!!.substringBeforeLast(':'); val port = target.substringAfterLast(':').toInt()
        val token = File(tokenFile!!).readText().trim()

        val client = PairedChannelClient(host, port, device!!, token)
        try {
            val health = client.request("GET", "/v1/health")
            assertEquals(200, health.status)
            assertTrue(String(health.body).contains("vergenced"))
            // A grant-checked route, on the same keep-alive connection: the PSK identity is the
            // authorization (no header sent), so an unknown title answers 404, not 401.
            val status = client.request("GET", "/v1/titles/jellyfin/not-a-title/smooth-motion-3d")
            assertEquals(404, status.status)
            assertTrue(String(status.body).contains("\"none\""))
            val posted = client.request("POST", "/v1/playing",
                """{"server":"jellyfin","id":"","seconds":0,"player":"test","stopped":true}""".toByteArray(), "application/json")
            assertEquals("the stopped report is accepted", 204, posted.status)
        } finally { client.close() }

        // A wrong token is a different PSK: the handshake fails.
        val wrong = PairedChannelClient(host, port, device, token + "x")
        try {
            wrong.request("GET", "/v1/health")
            fail("a wrong PSK must not connect")
        } catch (_: IOException) {
        } finally { wrong.close() }
    }
}
