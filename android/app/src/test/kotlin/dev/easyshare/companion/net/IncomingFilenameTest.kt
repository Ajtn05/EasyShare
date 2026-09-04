package dev.easyshare.companion.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class IncomingFilenameTest {
    @Test fun hostileNamesBecomeSingleVisibleComponents() {
        assertEquals("photo.jpg", IncomingFilename.sanitize("photo.jpg"))
        assertEquals("zshrc", IncomingFilename.sanitize("../../../.zshrc"))
        assertEquals("evil.dll", IncomingFilename.sanitize("..\\..\\windows\\system32\\evil.dll"))
        assertEquals("hidden", IncomingFilename.sanitize(".hidden"))
        assertEquals("twolines.txt", IncomingFilename.sanitize("two\nlines.txt"))
        assertEquals("file", IncomingFilename.sanitize(""))
        assertEquals("file", IncomingFilename.sanitize(".."))
        assertEquals("file", IncomingFilename.sanitize("..."))
        assertEquals("report-final.pdf", IncomingFilename.sanitize("report:final.pdf"))
        assertEquals("report.txt", IncomingFilename.sanitize("report\\u0000.txt".replace("\\u0000", "\u0000")))
    }

    @Test fun longNamesKeepShortExtensions() {
        val source = "x".repeat(240) + ".jpeg"
        val result = IncomingFilename.sanitize(source)
        assertEquals(200, result.length)
        assertTrue(result.endsWith(".jpeg"))
    }

    @Test fun multibyteNamesRespectTheFilesystemByteLimit() {
        val result = IncomingFilename.sanitize("😀".repeat(100) + ".jpeg")
        assertTrue(result.toByteArray(Charsets.UTF_8).size <= IncomingFilename.maximumLength)
        assertTrue(result.endsWith(".jpeg"))
    }
}
