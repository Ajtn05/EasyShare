package dev.easyshare.companion.net

/**
 * Mirrors the macOS IncomingFilename rules. Remote names are a filesystem
 * boundary even when they arrived over a paired and pinned connection.
 */
object IncomingFilename {
    const val fallback = "file"
    const val maximumLength = 200

    fun sanitize(raw: String): String {
        var name = raw.substringAfterLast('/').substringAfterLast('\\')
            .filterNot { it.isISOControl() || it == '/' || it == '\\' || it == '\u0000' }
            .replace(":", "-")
            .trim()
        while (name.startsWith('.')) name = name.drop(1)
        name = name.trim()
        if (name.isEmpty()) return fallback
        return truncatePreservingExtension(name, maximumLength)
    }

    private fun truncatePreservingExtension(name: String, limit: Int): String {
        if (name.toByteArray(Charsets.UTF_8).size <= limit) return name
        val dot = name.lastIndexOf('.')
        val extension = if (dot > 0) name.substring(dot + 1) else ""
        if (extension.isEmpty() || extension.toByteArray(Charsets.UTF_8).size > 10) {
            return truncateUtf8(name, limit)
        }
        val room = limit - extension.toByteArray(Charsets.UTF_8).size - 1
        return if (room > 0) truncateUtf8(name.substring(0, dot), room) + "." + extension
        else truncateUtf8(name, limit)
    }

    private fun truncateUtf8(value: String, limit: Int): String {
        val result = StringBuilder()
        var offset = 0
        var bytes = 0
        while (offset < value.length) {
            val codePoint = value.codePointAt(offset)
            val codePointBytes = String(Character.toChars(codePoint)).toByteArray(Charsets.UTF_8).size
            if (bytes + codePointBytes > limit) break
            result.appendCodePoint(codePoint)
            bytes += codePointBytes
            offset += Character.charCount(codePoint)
        }
        return result.toString()
    }
}
