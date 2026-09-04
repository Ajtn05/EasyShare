package dev.easyshare.companion.ui

import android.content.Context
import android.content.Intent
import android.graphics.Typeface
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import dev.easyshare.companion.net.CompanionReceiverService
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * A user-enabled overlay for the approval step. It contains its own controls,
 * never passes touches through the card, and is removed on every decision or
 * session cleanup. Android requires the separately granted overlay capability.
 */
object ApprovalOverlay {
    private val main = Handler(Looper.getMainLooper())
    private var windowManager: WindowManager? = null
    private var activeView: View? = null
    private var activeSession: String? = null

    fun show(
        context: Context,
        kind: String,
        session: String,
        title: String,
        detail: String,
        code: String?
    ): Boolean {
        if (!Settings.canDrawOverlays(context)) return false
        return onMain {
            dismissLocked()
            val manager = context.getSystemService(WindowManager::class.java)
            val card = buildCard(context.applicationContext, kind, session, title, detail, code)
            val width = (context.resources.displayMetrics.widthPixels * 0.90f).toInt()
            val parameters = WindowManager.LayoutParams(
                width,
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                android.graphics.PixelFormat.TRANSLUCENT
            ).apply {
                gravity = Gravity.CENTER
            }
            try {
                manager.addView(card, parameters)
                windowManager = manager
                activeView = card
                activeSession = session
                true
            } catch (_: Exception) {
                false
            }
        }
    }

    fun dismiss(context: Context, session: String) {
        onMain {
            if (activeSession == session) dismissLocked()
            true
        }
    }

    fun dismissAll(context: Context) {
        onMain {
            dismissLocked()
            true
        }
    }

    private fun buildCard(
        context: Context,
        kind: String,
        session: String,
        title: String,
        detail: String,
        code: String?
    ): View {
        val pairing = kind == ApprovalActivity.KIND_PAIRING
        val layout = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(context.dp(22), context.dp(22), context.dp(22), context.dp(22))
            background = context.rounded(context.colors.surface, Radius.SHEET)
            elevation = context.dp(12).toFloat()
        }
        layout.addView(context.eyebrowText(if (pairing) "PAIRING REQUEST" else "INCOMING FILES"))
        layout.addView(context.brandText(title, 20f, context.colors.ink, Typeface.BOLD), context.matchParent(top = 6))
        layout.addView(context.brandText(detail, 14f, context.colors.muted).apply {
            setLineSpacing(context.dp(3).toFloat(), 1f)
        }, context.matchParent(top = 8))
        if (pairing && !code.isNullOrBlank()) {
            layout.addView(context.brandText(code, 28f, context.colors.ink, Typeface.BOLD).apply {
                gravity = Gravity.CENTER
                letterSpacing = 0.12f
                background = context.rounded(context.colors.primarySurface, Radius.CHIP)
                setPadding(context.dp(16), context.dp(13), context.dp(16), context.dp(13))
            }, context.matchParent(top = 18))
            layout.addView(context.brandText("Approve only when this matches Finder.", 12f, context.colors.muted), context.matchParent(top = 8))
        }
        layout.addView(context.verticalSpace(20))
        val approveAction = if (pairing) CompanionReceiverService.ACTION_APPROVE_PAIR else CompanionReceiverService.ACTION_ACCEPT_TRANSFER
        layout.addView(context.brandButton(if (pairing) "Approve pairing" else "Accept files", context.colors.primary, context.colors.onPrimary).apply {
            setOnClickListener { decide(context, session, approveAction) }
        }, context.matchParent(height = 48))
        layout.addView(context.verticalSpace(8))
        val declineAction = if (pairing) CompanionReceiverService.ACTION_DECLINE_PAIR else CompanionReceiverService.ACTION_DECLINE_TRANSFER
        layout.addView(context.brandButton("Decline", context.colors.surface, context.colors.alert, strokeColor = context.colors.alert).apply {
            setOnClickListener { decide(context, session, declineAction) }
        }, context.matchParent(height = 48))
        return layout
    }

    private fun decide(context: Context, session: String, action: String) {
        dismiss(context, session)
        val intent = Intent(context, CompanionReceiverService::class.java).apply {
            this.action = action
            putExtra(CompanionReceiverService.EXTRA_SESSION, session)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent) else context.startService(intent)
    }

    private fun dismissLocked() {
        activeView?.let { view -> runCatching { windowManager?.removeViewImmediate(view) } }
        activeView = null
        activeSession = null
        windowManager = null
    }

    private fun onMain(block: () -> Boolean): Boolean {
        if (Looper.myLooper() == Looper.getMainLooper()) return block()
        val latch = CountDownLatch(1)
        var result = false
        main.post {
            result = block()
            latch.countDown()
        }
        latch.await(1, TimeUnit.SECONDS)
        return result
    }

}
