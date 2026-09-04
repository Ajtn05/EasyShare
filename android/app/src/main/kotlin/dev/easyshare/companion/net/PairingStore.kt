package dev.easyshare.companion.net

import android.content.Context
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

/** Tokens are random capabilities and are only transmitted over pinned TLS. */
class PairingStore(context: Context) {
    private val preferences = context.getSharedPreferences("paired-macs", Context.MODE_PRIVATE)

    fun accepts(token: ByteArray): Boolean = tokens().any { saved ->
        MessageDigest.isEqual(saved, token)
    }

    fun remember(token: ByteArray, name: String) {
        val values = entries().filterNot { MessageDigest.isEqual(it.token, token) }.toMutableList()
        values += Entry(token, PeerText.displayName(name, fallback = "Mac"))
        while (values.size > 8) values.removeAt(0)
        val json = JSONArray()
        values.forEach { entry ->
            json.put(JSONObject().put("token", CompanionProtocol.base64(entry.token)).put("name", entry.name))
        }
        preferences.edit().putString("entries", json.toString()).apply()
    }

    private fun tokens(): List<ByteArray> = entries().map(Entry::token)

    private fun entries(): List<Entry> = try {
        val text = preferences.getString("entries", "[]") ?: "[]"
        val json = JSONArray(text)
        List(json.length()) { index ->
            val entry = json.getJSONObject(index)
            Entry(CompanionProtocol.decodeBase64(entry.getString("token")), entry.optString("name", "Mac"))
        }.filter { it.token.size == 32 }
    } catch (_: Exception) {
        emptyList()
    }

    private data class Entry(val token: ByteArray, val name: String)
}
