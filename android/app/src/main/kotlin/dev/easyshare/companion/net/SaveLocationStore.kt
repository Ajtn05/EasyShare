package dev.easyshare.companion.net

import android.content.Context
import android.net.Uri

/** Persists the optional user-selected destination for received files. */
object SaveLocationStore {
    private const val PREFERENCES = "save-location"
    private const val TREE_URI = "tree-uri"

    fun treeUri(context: Context): Uri? = context
        .getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        .getString(TREE_URI, null)
        ?.let(Uri::parse)

    fun saveTreeUri(context: Context, uri: Uri) {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .edit()
            .putString(TREE_URI, uri.toString())
            .apply()
    }

    fun useDownloads(context: Context) {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .edit()
            .remove(TREE_URI)
            .apply()
    }
}
