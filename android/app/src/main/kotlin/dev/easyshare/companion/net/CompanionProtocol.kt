package dev.easyshare.companion.net

import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.security.SecureRandom

object CompanionProtocol {
    const val version = 1
    const val maximumEnvelopeBytes = 1_048_576
    const val maximumFiles = 512
    const val maximumTotalBytes = 100L * 1024 * 1024 * 1024

    fun readEnvelope(input: InputStream): JSONObject {
        val size = ByteBuffer.wrap(readExactly(input, 4)).order(ByteOrder.BIG_ENDIAN).int
        require(size in 2..maximumEnvelopeBytes) { "invalid companion envelope length" }
        return JSONObject(String(readExactly(input, size), Charsets.UTF_8))
    }

    fun writeEnvelope(output: OutputStream, value: JSONObject) {
        val bytes = value.toString().toByteArray(Charsets.UTF_8)
        require(bytes.size <= maximumEnvelopeBytes) { "companion envelope too large" }
        output.write(ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(bytes.size).array())
        output.write(bytes)
        output.flush()
    }

    fun readExactly(input: InputStream, size: Int): ByteArray {
        val output = ByteArray(size)
        var offset = 0
        while (offset < size) {
            val count = input.read(output, offset, size - offset)
            if (count <= 0) throw EOFException("truncated companion stream")
            offset += count
        }
        return output
    }

    fun randomBytes(size: Int): ByteArray = ByteArray(size).also(SecureRandom()::nextBytes)
    fun base64(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.NO_WRAP)
    fun base64Url(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    fun decodeBase64(value: String): ByteArray = Base64.decode(value, Base64.DEFAULT)

    fun comparisonCode(challenge: ByteArray, fingerprintHex: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(challenge + fingerprintHex.toByteArray(Charsets.US_ASCII))
        val number = ByteBuffer.wrap(digest, 0, 4).order(ByteOrder.BIG_ENDIAN).int.toLong() and 0xffff_ffffL
        return (number % 1_000_000L).toString().padStart(6, '0')
    }

    fun requiredString(value: JSONObject, key: String, maximumBytes: Int): String {
        val result = value.optString(key, "")
        require(result.isNotBlank() && result.toByteArray(Charsets.UTF_8).size <= maximumBytes) {
            "invalid $key"
        }
        return result
    }

    data class FileMeta(val name: String, val size: Long, val mimeType: String)

    fun files(value: JSONArray): List<FileMeta> {
        require(value.length() in 1..maximumFiles) { "invalid file count" }
        var total = 0L
        return List(value.length()) { index ->
            val entry = value.getJSONObject(index)
            val name = requiredString(entry, "name", 1_024)
            val size = entry.optLong("size", -1)
            val mimeType = entry.optString("mime", "application/octet-stream").take(255)
            require(size >= 0 && total <= maximumTotalBytes - size) { "invalid file size" }
            total += size
            FileMeta(name, size, mimeType)
        }
    }
}
