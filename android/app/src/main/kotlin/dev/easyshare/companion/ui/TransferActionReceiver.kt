package dev.easyshare.companion.ui

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import dev.easyshare.companion.net.CompanionReceiverService

/** Notification actions are routed back to the existing foreground receiver. */
class TransferActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action !in setOf(
                CompanionReceiverService.ACTION_STOP,
                CompanionReceiverService.ACTION_ENABLE_PAIRING,
                CompanionReceiverService.ACTION_APPROVE_PAIR,
                CompanionReceiverService.ACTION_DECLINE_PAIR,
                CompanionReceiverService.ACTION_ACCEPT_TRANSFER,
                CompanionReceiverService.ACTION_DECLINE_TRANSFER
            )
        ) return
        context.startService(Intent(context, CompanionReceiverService::class.java).apply {
            this.action = action
            putExtra(CompanionReceiverService.EXTRA_SESSION, intent.getStringExtra(CompanionReceiverService.EXTRA_SESSION))
        })
    }
}
