package dev.easyshare.companion.ui

import android.Manifest
import android.app.Activity
import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Typeface
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.net.Uri
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast
import dev.easyshare.companion.R
import dev.easyshare.companion.net.CompanionReceiverService
import dev.easyshare.companion.net.SaveLocationStore
import java.util.function.Consumer

class MainActivity : Activity() {
    private lateinit var statusCard: LinearLayout
    private lateinit var statusDot: View
    private lateinit var statusTitle: TextView
    private lateinit var statusDetail: TextView
    private lateinit var primaryButton: Button
    private lateinit var pairButton: Button
    private lateinit var tileDetail: TextView
    private lateinit var approvalToggle: Switch
    private lateinit var approvalDetail: TextView
    private lateinit var saveLocationDetail: TextView
    private lateinit var saveLocationButton: Button
    private lateinit var saveLocationResetButton: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = if (isDarkMode) colors.background else colors.ink
        window.navigationBarColor = colors.surface
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            window.decorView.systemUiVisibility =
                if (colors.systemBarsLight) View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR else 0
        }
        setContentView(buildContent())
        requestRuntimePermissions()
    }

    override fun onResume() {
        super.onResume()
        renderStatus()
        renderSaveLocation()
    }

    private fun buildContent(): View {
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(22), dp(38), dp(22), dp(24))
        }
        val scroll = ScrollView(this).apply {
            isFillViewport = true
            setBackgroundColor(colors.background)
            addView(content)
        }

        val headerIcon = ImageView(this).apply {
            setImageResource(R.drawable.ic_brand_mark)
            contentDescription = null
        }
        val headerText = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(brandText("Easy Share", 21f, colors.ink, Typeface.BOLD))
            addView(brandText("Send from your Mac with a one-time pairing. Android’s built-in Quick Share still sends to your Mac.", 13f, colors.muted).apply {
                setLineSpacing(dp(2).toFloat(), 1f)
            }, matchParent(top = 3))
        }
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(headerIcon, LinearLayout.LayoutParams(dp(44), dp(44)))
            addView(horizontalSpace(12))
            addView(headerText, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        }
        content.addView(header, matchParent())
        content.addView(verticalSpace(22))

        statusCard = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(14), dp(16), dp(14))
        }
        val statusTop = LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            statusDot = View(this@MainActivity)
            addView(statusDot, LinearLayout.LayoutParams(dp(8), dp(8)))
            addView(horizontalSpace(9))
            statusTitle = brandText("Checking receiver…", 15f, colors.ink, Typeface.BOLD)
            addView(statusTitle, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        }
        statusCard.addView(statusTop)
        statusDetail = brandText("", 13f, colors.muted).apply {
            setLineSpacing(dp(2).toFloat(), 1f)
        }
        statusCard.addView(statusDetail, matchParent(top = 6))
        content.addView(statusCard, matchParent())
        content.addView(verticalSpace(14))

        primaryButton = brandButton("Turn on receiver", colors.primary, colors.onPrimary).apply {
            setOnClickListener {
                startReceiver(if (CompanionReceiverService.isEnabled(this@MainActivity)) {
                    CompanionReceiverService.ACTION_STOP
                } else {
                    CompanionReceiverService.ACTION_START
                })
            }
        }
        content.addView(primaryButton, matchParent(height = 48))
        content.addView(verticalSpace(8))

        pairButton = brandButton("Pair a new Mac", colors.surface, colors.primary, strokeColor = colors.primary).apply {
            setOnClickListener { startReceiver(CompanionReceiverService.ACTION_ENABLE_PAIRING) }
        }
        content.addView(pairButton, matchParent(height = 48))
        content.addView(brandText("Pairing is open for two minutes. A matching code appears only when your Mac connects.", 12f, colors.muted), matchParent(top = 8))
        content.addView(verticalSpace(24))

        content.addView(sectionLabel("SAVE LOCATION"))
        content.addView(brandText("Save received files to", 16f, colors.ink, Typeface.BOLD), matchParent(top = 6))
        saveLocationDetail = brandText("", 13f, colors.muted).apply {
            setLineSpacing(dp(2).toFloat(), 1f)
        }
        content.addView(saveLocationDetail, matchParent(top = 5))
        saveLocationButton = brandButton("Choose a folder", colors.surface, colors.primary, strokeColor = colors.primary).apply {
            setOnClickListener { chooseSaveFolder() }
        }
        content.addView(saveLocationButton, matchParent(top = 12, height = 46))
        saveLocationResetButton = brandButton("Use Downloads", colors.surface, colors.muted, strokeColor = colors.muted).apply {
            setOnClickListener {
                SaveLocationStore.useDownloads(this@MainActivity)
                renderSaveLocation()
            }
        }
        content.addView(saveLocationResetButton, matchParent(top = 8, height = 46))
        content.addView(verticalSpace(24))

        content.addView(sectionLabel("QUICK SETTINGS"))
        content.addView(brandText("Keep the receiver one swipe away", 16f, colors.ink, Typeface.BOLD), matchParent(top = 6))
        tileDetail = brandText("Add the Receive from Mac tile to toggle availability without reopening this app.", 13f, colors.muted).apply {
            setLineSpacing(dp(2).toFloat(), 1f)
        }
        content.addView(tileDetail, matchParent(top = 5))
        val tileButton = brandButton("Add to Quick Settings", colors.ink, colors.background).apply {
            setOnClickListener { requestQuickSettingsTile() }
        }
        content.addView(tileButton, matchParent(top = 12, height = 46))
        content.addView(verticalSpace(24))

        content.addView(sectionLabel("APPROVAL STYLE"))
        val approvalRow = LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            orientation = LinearLayout.HORIZONTAL
            addView(brandText("Floating approval card", 16f, colors.ink, Typeface.BOLD), LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            approvalToggle = Switch(this@MainActivity).apply {
                isChecked = ApprovalStyleStore.overlayRequested(this@MainActivity)
            }
            addView(approvalToggle)
        }
        content.addView(approvalRow, matchParent(top = 6))
        approvalDetail = brandText("Notifications show Approve and Decline actions.", 13f, colors.muted).apply {
            setLineSpacing(dp(2).toFloat(), 1f)
        }
        content.addView(approvalDetail, matchParent(top = 4))
        approvalToggle.setOnCheckedChangeListener { _, enabled ->
            ApprovalStyleStore.setOverlayRequested(this, enabled)
            renderApprovalStyle()
            if (enabled && !Settings.canDrawOverlays(this)) requestOverlayPermission()
        }

        content.addView(verticalSpace(20))
        content.addView(brandText("Files are saved only after you accept them.", 12f, colors.muted).apply {
            gravity = Gravity.CENTER_HORIZONTAL
        }, matchParent())
        return scroll
    }

    private fun startReceiver(action: String) {
        val intent = Intent(this, CompanionReceiverService::class.java).setAction(action)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
        statusDetail.postDelayed({ renderStatus() }, 400)
    }

    private fun renderStatus() {
        val diagnostic = CompanionReceiverService.diagnostic(this)
        val pairing = CompanionReceiverService.isPairingEnabled(this)
        val receiving = CompanionReceiverService.isEnabled(this)
        when {
            diagnostic != null -> showStatus("Receiver needs attention", diagnostic, colors.alert, colors.alertSurface)
            pairing -> showStatus(
                "Ready to pair",
                "In Finder, select this Android companion and compare the six-digit code before approving.",
                colors.primary,
                colors.primarySurface
            )
            receiving -> showStatus(
                "Receiver is on",
                "Paired Macs can send a file. You will always be asked to accept it first.",
                colors.success,
                colors.successSurface
            )
            else -> showStatus(
                "Receiver is off",
                "Turn it on whenever you want this phone to appear in Easy Share on your Mac.",
                colors.muted,
                colors.surface
            )
        }
        primaryButton.text = if (receiving) "Turn off receiver" else "Turn on receiver"
        pairButton.alpha = if (receiving || pairing) 1f else 0.92f
        renderApprovalStyle()
    }

    private fun showStatus(title: String, detail: String, dot: Int, surface: Int) {
        statusTitle.text = title
        statusDetail.text = detail
        statusCard.background = rounded(surface, Radius.CARD)
        statusDot.background = oval(dot)
    }

    private fun requestQuickSettingsTile() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            tileDetail.text = "Swipe down twice, tap Edit, then add Receive from Mac to Quick Settings."
            return
        }
        val manager = getSystemService(StatusBarManager::class.java)
        manager.requestAddTileService(
            ComponentName(this, ReceiverTileService::class.java),
            "Receive from Mac",
            Icon.createWithResource(this, R.drawable.ic_receiver_tile),
            mainExecutor,
            Consumer { result ->
                tileDetail.text = when (result) {
                    StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED -> "Receive from Mac is now in Quick Settings."
                    StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED -> "Receive from Mac is already in Quick Settings."
                    else -> "You can add Receive from Mac later from the Quick Settings edit screen."
                }
            }
        )
    }

    private fun renderApprovalStyle() {
        val overlay = ApprovalStyleStore.overlayRequested(this)
        if (approvalToggle.isChecked != overlay) approvalToggle.isChecked = overlay
        approvalDetail.text = when {
            !overlay -> "Notifications show Approve and Decline actions."
            Settings.canDrawOverlays(this) -> "Incoming requests appear automatically as a floating approval card."
            else -> "Enable Display over other apps to use floating cards. Until then, approvals stay in notifications."
        }
    }

    private fun renderSaveLocation() {
        val customFolder = SaveLocationStore.treeUri(this) != null
        saveLocationDetail.text = if (customFolder) {
            "Selected folder. New files will be saved there after you accept them."
        } else {
            "Downloads (default). Choose another folder if you prefer."
        }
        saveLocationButton.text = if (customFolder) "Choose another folder" else "Choose a folder"
        saveLocationResetButton.visibility = if (customFolder) View.VISIBLE else View.GONE
    }

    private fun chooseSaveFolder() {
        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
            )
        }, REQUEST_SAVE_FOLDER)
    }

    @Deprecated("Replaced by Activity Result APIs; kept to avoid adding a UI framework dependency.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_SAVE_FOLDER || resultCode != RESULT_OK) return
        val uri = data?.data ?: return
        val flags = data.flags and (
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        )
        try {
            contentResolver.takePersistableUriPermission(uri, flags)
            SaveLocationStore.saveTreeUri(this, uri)
            renderSaveLocation()
        } catch (_: SecurityException) {
            Toast.makeText(this, "Couldn’t save access to that folder.", Toast.LENGTH_LONG).show()
        }
    }

    private fun requestOverlayPermission() {
        val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName"))
        if (intent.resolveActivity(packageManager) != null) startActivity(intent)
        else startActivity(Intent(Settings.ACTION_SETTINGS))
    }

    private fun requestRuntimePermissions() {
        if (Build.VERSION.SDK_INT < 33) return
        val needed = buildList {
            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                add(Manifest.permission.POST_NOTIFICATIONS)
            }
            if (checkSelfPermission(Manifest.permission.NEARBY_WIFI_DEVICES) != PackageManager.PERMISSION_GRANTED) {
                add(Manifest.permission.NEARBY_WIFI_DEVICES)
            }
        }
        if (needed.isNotEmpty()) requestPermissions(needed.toTypedArray(), 1)
    }

    companion object {
        private const val REQUEST_SAVE_FOLDER = 4101
    }
}
