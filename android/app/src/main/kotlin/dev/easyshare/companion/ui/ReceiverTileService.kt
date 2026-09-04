package dev.easyshare.companion.ui

import android.content.Intent
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import dev.easyshare.companion.net.CompanionReceiverService

/** The one-tap control after the first pairing. It never implies a reboot survives. */
class ReceiverTileService : TileService() {
    override fun onStartListening() = updateTile()

    override fun onClick() {
        val action = if (CompanionReceiverService.isEnabled(this)) {
            CompanionReceiverService.ACTION_STOP
        } else {
            CompanionReceiverService.ACTION_START
        }
        startForegroundService(Intent(this, CompanionReceiverService::class.java).setAction(action))
        updateTile(action == CompanionReceiverService.ACTION_START)
    }

    private fun updateTile(enabled: Boolean = CompanionReceiverService.isEnabled(this)) {
        qsTile?.apply {
            state = if (enabled) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            stateDescription = if (enabled) "On — ready to receive" else "Off"
            contentDescription = "Receive from Mac: ${if (enabled) "on" else "off"}"
            updateTile()
        }
    }
}
