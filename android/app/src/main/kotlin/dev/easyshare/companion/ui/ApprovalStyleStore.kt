package dev.easyshare.companion.ui

import android.content.Context

object ApprovalStyleStore {
    private const val PREFERENCES = "approval-style"
    private const val OVERLAY_KEY = "use-overlay"

    fun overlayRequested(context: Context): Boolean =
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getBoolean(OVERLAY_KEY, false)

    fun setOverlayRequested(context: Context, enabled: Boolean) {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(OVERLAY_KEY, enabled)
            .apply()
    }
}
