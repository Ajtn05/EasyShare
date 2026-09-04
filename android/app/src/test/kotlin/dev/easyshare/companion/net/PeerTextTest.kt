package dev.easyshare.companion.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PeerTextTest {
    @Test fun peerNamesCannotInjectControlsOrExceedBonjourLimit() {
        assertEquals("Mac", PeerText.displayName("\u202eMac\u2066"))
        assertEquals("Android", PeerText.displayName("\n\u0000", fallback = "Android"))

        val result = PeerText.displayName("😀".repeat(30))
        assertTrue(result.toByteArray(Charsets.UTF_8).size <= PeerText.maximumDisplayNameBytes)
    }
}
