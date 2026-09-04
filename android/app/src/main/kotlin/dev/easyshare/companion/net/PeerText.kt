package dev.easyshare.companion.net

/**
 * Names from a peer are display data, never trusted text. Keep the rules in
 * one place so the name shown in an approval, stored for a pairing, and put in
 * mDNS all have the same bounded, non-spoofing form.
 */
object PeerText {
    const val maximumDisplayNameBytes = 63

    fun displayName(raw: String, fallback: String = "Unknown device"): String {
        val cleaned = StringBuilder().also { result ->
            var offset = 0
            while (offset < raw.length) {
                val codePoint = raw.codePointAt(offset)
                if (!Character.isISOControl(codePoint) && Character.getType(codePoint) != Character.FORMAT.toInt()) {
                    result.appendCodePoint(codePoint)
                }
                offset += Character.charCount(codePoint)
            }
        }.toString().trim()
        return truncateUtf8(cleaned.ifEmpty { fallback }, maximumDisplayNameBytes)
            .ifEmpty { "Unknown device" }
    }

    private fun truncateUtf8(value: String, limit: Int): String {
        val result = StringBuilder()
        var offset = 0
        var bytes = 0
        while (offset < value.length) {
            val codePoint = value.codePointAt(offset)
            val count = String(Character.toChars(codePoint)).toByteArray(Charsets.UTF_8).size
            if (bytes + count > limit) break
            result.appendCodePoint(codePoint)
            bytes += count
            offset += Character.charCount(codePoint)
        }
        return result.toString()
    }
}
