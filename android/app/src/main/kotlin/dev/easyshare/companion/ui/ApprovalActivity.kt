package dev.easyshare.companion.ui

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import android.view.Gravity
import android.view.View
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import dev.easyshare.companion.R
import dev.easyshare.companion.net.CompanionReceiverService

class ApprovalActivity : Activity() {
    private lateinit var session: String
    private lateinit var approvalAction: String

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        session = intent.getStringExtra(EXTRA_SESSION).orEmpty()
        val kind = intent.getStringExtra(EXTRA_KIND)
        val title = intent.getStringExtra(EXTRA_TITLE).orEmpty()
        val detail = intent.getStringExtra(EXTRA_DETAIL).orEmpty()
        val code = intent.getStringExtra(EXTRA_CODE)
        if (session.isBlank() || kind !in setOf(KIND_PAIRING, KIND_TRANSFER)) {
            finish()
            return
        }
        approvalAction = if (kind == KIND_PAIRING) {
            CompanionReceiverService.ACTION_APPROVE_PAIR
        } else {
            CompanionReceiverService.ACTION_ACCEPT_TRANSFER
        }

        window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        window.attributes = window.attributes.apply { dimAmount = 0.42f }
        setContentView(content(title, detail, code, kind == KIND_PAIRING))
        window.setLayout((resources.displayMetrics.widthPixels * 0.90f).toInt(), WindowManager.LayoutParams.WRAP_CONTENT)
    }

    private fun content(title: String, detail: String, code: String?, isPairing: Boolean): View {
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(22), dp(24), dp(22), dp(22))
            background = rounded(colors.surface, Radius.SHEET)
        }
        layout.addView(ImageView(this).apply {
            setImageResource(R.drawable.ic_brand_mark)
            contentDescription = null
        }, LinearLayout.LayoutParams(dp(52), dp(52)))
        layout.addView(verticalSpace(16))
        layout.addView(eyebrowText(if (isPairing) "PAIRING REQUEST" else "INCOMING FILES"))
        layout.addView(brandText(title, 21f, colors.ink, Typeface.BOLD).apply { gravity = Gravity.CENTER }, matchParent(top = 6))
        layout.addView(brandText(detail, 14f, colors.muted).apply {
            gravity = Gravity.CENTER
            setLineSpacing(dp(3).toFloat(), 1f)
        }, matchParent(top = 10))
        if (isPairing && !code.isNullOrBlank()) {
            val codeCard = TextView(this).apply {
                text = code
                textSize = 28f
                letterSpacing = 0.13f
                typeface = Typeface.DEFAULT_BOLD
                gravity = Gravity.CENTER
                setTextColor(colors.ink)
                background = rounded(colors.primarySurface, Radius.CARD)
                setPadding(dp(16), dp(14), dp(16), dp(14))
            }
            layout.addView(codeCard, matchParent(top = 20))
            layout.addView(brandText("Approve only if this matches the code in Finder.", 12f, colors.muted).apply {
                gravity = Gravity.CENTER
            }, matchParent(top = 10))
        }
        layout.addView(verticalSpace(22))
        val acceptLabel = if (isPairing) "Approve pairing" else "Accept files"
        layout.addView(brandButton(acceptLabel, colors.primary, colors.onPrimary).apply {
            setOnClickListener { decide(approvalAction) }
        }, matchParent(height = 48))
        layout.addView(verticalSpace(10))
        val decline = if (isPairing) CompanionReceiverService.ACTION_DECLINE_PAIR else CompanionReceiverService.ACTION_DECLINE_TRANSFER
        layout.addView(brandButton("Decline", colors.surface, colors.alert, strokeColor = colors.alert).apply {
            setOnClickListener { decide(decline) }
        }, matchParent(height = 48))
        layout.addView(brandText("Accepted files are saved to Downloads.", 12f, colors.muted).apply {
            gravity = Gravity.CENTER
        }, matchParent(top = 16))
        return layout
    }

    private fun decide(action: String) {
        val service = Intent(this, CompanionReceiverService::class.java).apply {
            this.action = action
            putExtra(CompanionReceiverService.EXTRA_SESSION, session)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(service) else startService(service)
        finish()
    }

    companion object {
        const val KIND_PAIRING = "pairing"
        const val KIND_TRANSFER = "transfer"
        const val EXTRA_KIND = "approval-kind"
        const val EXTRA_SESSION = "approval-session"
        const val EXTRA_TITLE = "approval-title"
        const val EXTRA_DETAIL = "approval-detail"
        const val EXTRA_CODE = "approval-code"
    }
}
