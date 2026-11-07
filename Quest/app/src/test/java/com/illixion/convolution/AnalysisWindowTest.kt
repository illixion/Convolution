package com.illixion.convolution

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The coordinator-reading rules, matched to the Vision Pro's and VergenceCore's (see AnalysisWindow.kt). */
class AnalysisWindowTest {
    @Test fun playheadIsReportedEveryFiveSecondsAndAtOnceAfterASeek() {
        val rule = PlayheadRule()
        rule.start(100.0, now = 0.0)
        assertFalse("steady play, 1 s in", rule.due(101.0, now = 1.0))
        assertFalse("steady play, 4.9 s in", rule.due(104.9, now = 4.9))
        assertTrue("five seconds on", rule.due(105.0, now = 5.0))
        assertFalse(rule.due(106.0, now = 6.0))
        assertTrue("a seek forward", rule.due(300.0, now = 6.5))
        assertFalse("playing on from the seek", rule.due(301.0, now = 7.5))
        assertTrue("a seek back", rule.due(290.0, now = 8.0))
        assertFalse("paused within the slack", rule.due(290.0, now = 10.5))
        assertTrue("paused longer than the slack reads as a seek", rule.due(290.0, now = 11.5))
    }

    @Test fun chunksAroundThePlayheadNearestFirstTwoAtATime() {
        val window = ChunkWindow(chunkSeconds = 10.0, chunkCount = 20)
        assertEquals("one behind, the chunk, three ahead and one more kept", 0..5, window.noteDemand(15.0))
        assertNull("the same chunk changes nothing", window.noteDemand(19.9))
        assertEquals(listOf(1, 2), window.next(now = 0.0))
        assertEquals("both in flight", emptyList<Int>(), window.next(now = 0.0))
        assertTrue(window.finished(1, success = true, complete = true, now = 0.2))
        assertEquals(listOf(3), window.next(now = 0.2))
        assertTrue(window.holdsWhole(12.0))
        assertFalse(window.holdsWhole(25.0))
    }

    @Test fun partialChunksAreFetchedAgainAndFailuresRetried() {
        val window = ChunkWindow(chunkSeconds = 10.0, chunkCount = 4, lookAhead = 1, concurrent = 4)
        window.noteDemand(0.0)
        assertEquals(listOf(0, 1), window.next(now = 0.0))
        assertTrue(window.finished(0, success = true, complete = false, now = 1.0))
        assertFalse("a 404 or an error stores nothing", window.finished(1, success = false, complete = false, now = 1.0))
        assertEquals("nothing until 1.5 s pass", emptyList<Int>(), window.next(now = 2.0))
        assertEquals(listOf(0, 1), window.next(now = 2.6))
        assertTrue(window.finished(0, success = true, complete = true, now = 2.7))
        window.finished(1, success = true, complete = true, now = 2.7)
        assertEquals("whole chunks are never fetched again", emptyList<Int>(), window.next(now = 10.0))
        assertFalse("the window ends at the title's last chunk", window.next(now = 10.0).contains(4))
    }

    @Test fun aSeekDropsChunksOutsideTheNewWindow() {
        val window = ChunkWindow(chunkSeconds = 10.0, chunkCount = 100)
        window.noteDemand(0.0)
        window.next(now = 0.0)
        window.finished(0, success = true, complete = true, now = 0.1)
        assertEquals(49..54, window.noteDemand(500.0))
        assertFalse(window.holdsWhole(0.0))
        assertFalse("a late chunk from before the seek is not kept", window.finished(1, success = true, complete = true, now = 0.2))
        assertEquals(listOf(50, 51), window.next(now = 0.3))
    }

    @Test fun pairingLinksParseAsRaveCompanionWritesThem() {
        val link = PairLink.parse("vergence://pair?mac=ABC-1&name=Studio%20Mac&port=4869&addr=192.168.1.5&addr=100.64.0.3")
        assertEquals(PairLink("ABC-1", "Studio Mac", 4869, listOf("192.168.1.5", "100.64.0.3")), link)
        assertEquals(4869, PairLink.parse("vergence://pair?mac=x&addr=10.0.0.2")?.port)
        assertNull("another app's link", PairLink.parse("longwave://pair?mac=x&addr=10.0.0.2"))
        assertNull("no address", PairLink.parse("vergence://pair?mac=x&name=y"))
        assertNull("a bad port", PairLink.parse("vergence://pair?addr=10.0.0.2&port=99999"))
    }

    @Test fun coordinatorAddressesTakeTheDefaultPort() {
        assertEquals("http://192.168.1.5:8420", coordinatorBaseUrl("192.168.1.5"))
        assertEquals("http://server.local:9000", coordinatorBaseUrl("http://server.local:9000/"))
        assertEquals("https://example.org:443", coordinatorBaseUrl("https://example.org"))
        assertEquals("http://[fe80::1]:8420", coordinatorBaseUrl("http://[fe80::1]"))
        assertNull(coordinatorBaseUrl(""))
        assertNull(coordinatorBaseUrl("ftp://host"))
    }

    @Test fun pairingTargetsFromWhatWasTyped() {
        assertEquals("192.168.1.20" to 4869, pairTarget(" 192.168.1.20 "))
        assertEquals("pc.local" to 5000, pairTarget("pc.local:5000"))
        assertEquals("fd00::5" to 4869, pairTarget("fd00::5"))
        assertEquals("fd00::5" to 4870, pairTarget("[fd00::5]:4870"))
        assertEquals("10.0.0.2" to 4869, pairTarget("vergence://pair?mac=x&addr=10.0.0.2"))
        assertNull(pairTarget("http://pc:8420"))
        assertNull(pairTarget("pc:99999"))
        assertNull(pairTarget(""))
    }
}
