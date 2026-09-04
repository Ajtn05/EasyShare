package dev.easyshare.companion.net

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.MediaStore
import dev.easyshare.companion.R
import dev.easyshare.companion.crypto.CompanionIdentity
import dev.easyshare.companion.ui.ApprovalActivity
import dev.easyshare.companion.ui.ApprovalOverlay
import dev.easyshare.companion.ui.ApprovalStyleStore
import java.io.BufferedOutputStream
import java.net.InetSocketAddress
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket

/** Foreground receiver for locally paired Macs. */
class CompanionReceiverService : Service() {
    private val workers = Executors.newFixedThreadPool(MAX_CONCURRENT_CONNECTIONS + 1)
    private val connectionPermits = Semaphore(MAX_CONCURRENT_CONNECTIONS)
    private val activeSockets = ConcurrentHashMap.newKeySet<SSLSocket>()
    private val pairings by lazy { PairingStore(this) }
    private val discovery by lazy { CompanionDiscovery(this) }
    private val pairingSessions = ConcurrentHashMap<String, PairingSession>()
    private val transferSessions = ConcurrentHashMap<String, TransferSession>()
    private val notificationHandler = Handler(Looper.getMainLooper())

    @Volatile private var server: SSLServerSocket? = null
    @Volatile private var receiving = false
    @Volatile private var pairingEnabledUntil = 0L
    private var pairingExpiryCallback: Runnable? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_START
        val session = intent?.getStringExtra(EXTRA_SESSION)
        when (action) {
            ACTION_START -> {
                clearDiagnostic()
                startReceiving()
            }
            ACTION_STOP -> stopReceiving()
            ACTION_ENABLE_PAIRING -> {
                clearDiagnostic()
                enablePairing()
            }
            ACTION_APPROVE_PAIR, ACTION_DECLINE_PAIR -> decidePairing(
                session, action == ACTION_APPROVE_PAIR
            )
            ACTION_ACCEPT_TRANSFER, ACTION_DECLINE_TRANSFER -> decideTransfer(
                session, action == ACTION_ACCEPT_TRANSFER
            )
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopReceiving()
        workers.shutdownNow()
        super.onDestroy()
    }

    private fun startReceiving() {
        if (receiving) return
        restorePairingWindow()
        createChannels()
        startForeground(READY_NOTIFICATION_ID, readyNotification())
        try {
            val socket = CompanionIdentity.tlsContext(this).serverSocketFactory.createServerSocket() as SSLServerSocket
            socket.reuseAddress = true
            socket.bind(InetSocketAddress(0))
            socket.enabledProtocols = arrayOf("TLSv1.3")
            server = socket
            receiving = true
            statePreferences(this).edit().putBoolean(RECEIVING_KEY, true).apply()
            discovery.register(socket.localPort, deviceName())
            workers.execute {
                while (receiving) {
                    val peer = try { socket.accept() as SSLSocket } catch (_: Exception) { break }
                    if (!receiving || !connectionPermits.tryAcquire()) {
                        runCatching { peer.close() }
                        continue
                    }
                    activeSockets.add(peer)
                    if (!receiving) {
                        activeSockets.remove(peer)
                        connectionPermits.release()
                        runCatching { peer.close() }
                        continue
                    }
                    try {
                        workers.execute {
                            try {
                                handle(peer)
                            } finally {
                                activeSockets.remove(peer)
                                connectionPermits.release()
                            }
                        }
                    } catch (_: RejectedExecutionException) {
                        activeSockets.remove(peer)
                        connectionPermits.release()
                        runCatching { peer.close() }
                    }
                }
            }
            updateReadyNotification()
        } catch (error: Exception) {
            recordDiagnostic("Couldn't start receiver: ${describe(error)}")
            stopReceiving()
        }
    }

    private fun stopReceiving() {
        receiving = false
        pairingExpiryCallback?.let(notificationHandler::removeCallbacks)
        pairingExpiryCallback = null
        statePreferences(this).edit()
            .putBoolean(RECEIVING_KEY, false)
            .putLong(PAIRING_UNTIL_KEY, 0)
            .apply()
        discovery.unregister()
        runCatching { server?.close() }
        server = null
        activeSockets.forEach { peer -> runCatching { peer.close() } }
        pairingSessions.forEach { (id, session) ->
            session.resolve(false)
            notificationManager().cancel(pairNotificationId(id))
            ApprovalOverlay.dismiss(this, id)
        }
        transferSessions.forEach { (id, session) ->
            session.resolve(false)
            notificationManager().cancel(transferNotificationId(id))
            ApprovalOverlay.dismiss(this, id)
        }
        pairingSessions.clear()
        transferSessions.clear()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun enablePairing() {
        if (!receiving) startReceiving()
        if (!receiving) return
        pairingEnabledUntil = System.currentTimeMillis() + PAIRING_WINDOW_MILLIS
        statePreferences(this).edit().putLong(PAIRING_UNTIL_KEY, pairingEnabledUntil).apply()
        schedulePairingExpiry()
        updateReadyNotification()
    }

    private fun decidePairing(id: String?, approved: Boolean) {
        id?.let { sessionID ->
            pairingSessions.remove(sessionID)?.resolve(approved)
            notificationManager().cancel(pairNotificationId(sessionID))
            ApprovalOverlay.dismiss(this, sessionID)
        }
    }

    private fun decideTransfer(id: String?, approved: Boolean) {
        id?.let { sessionID ->
            transferSessions.remove(sessionID)?.resolve(approved)
            notificationManager().cancel(transferNotificationId(sessionID))
            ApprovalOverlay.dismiss(this, sessionID)
        }
    }

    private fun handle(socket: SSLSocket) {
        socket.use { peer ->
            try {
                peer.enabledProtocols = arrayOf("TLSv1.3")
                peer.soTimeout = SOCKET_TIMEOUT_MILLIS.toInt()
                peer.startHandshake()
                val input = peer.inputStream
                val output = peer.outputStream
                val envelope = CompanionProtocol.readEnvelope(input)
                require(envelope.optInt("v", 0) == CompanionProtocol.version) { "unsupported companion version" }
                when (envelope.optString("op")) {
                    "pair-begin" -> beginPairing(envelope, input, output)
                    "send" -> receiveTransfer(envelope, input, output)
                    else -> fail(output, "Unsupported request")
                }
            } catch (error: Exception) {
                recordDiagnostic("Secure connection failed: ${describe(error)}")
                runCatching { fail(peer.outputStream, error.message ?: "Connection failed") }
            }
        }
    }

    private fun beginPairing(
        request: org.json.JSONObject,
        input: java.io.InputStream,
        output: java.io.OutputStream
    ) {
        require(System.currentTimeMillis() < pairingEnabledUntil) { "Enable Pair new Mac on Android first" }
        val challenge = CompanionProtocol.decodeBase64(CompanionProtocol.requiredString(request, "challenge", 128))
        require(challenge.size == 32) { "invalid pairing challenge" }
        val macName = PeerText.displayName(
            CompanionProtocol.requiredString(request, "macName", 128), fallback = "Mac"
        )
        val id = CompanionProtocol.base64Url(CompanionProtocol.randomBytes(16))
        val code = CompanionProtocol.comparisonCode(challenge, CompanionIdentity.fingerprintHex(this))
        val session = PairingSession(id, macName)
        pairingSessions[id] = session
        try {
            showPairingNotification(session, code)
            CompanionProtocol.writeEnvelope(output, org.json.JSONObject().put("op", "pairing-ready").put("session", id))

            val confirmation = CompanionProtocol.readEnvelope(input)
            require(
                confirmation.optInt("v", 0) == CompanionProtocol.version
                    && confirmation.optString("op") == "pair-confirm"
                    && confirmation.optString("session") == id
            ) { "invalid pairing confirmation" }

            if (!session.await()) {
                fail(output, "Pairing was declined or timed out")
                return
            }
            val token = CompanionProtocol.randomBytes(32)
            pairings.remember(token, macName)
            CompanionProtocol.writeEnvelope(output, org.json.JSONObject().put("op", "paired").put("token", CompanionProtocol.base64(token)))
        } finally {
            pairingSessions.remove(id)
            notificationManager().cancel(pairNotificationId(id))
            ApprovalOverlay.dismiss(this, id)
        }
    }

    private fun receiveTransfer(
        request: org.json.JSONObject,
        input: java.io.InputStream,
        output: java.io.OutputStream
    ) {
        val token = CompanionProtocol.decodeBase64(CompanionProtocol.requiredString(request, "token", 128))
        require(token.size == 32 && pairings.accepts(token)) { "This Mac is not paired" }
        val files = CompanionProtocol.files(request.getJSONArray("files"))
        val sender = PeerText.displayName(request.optString("sender", "Mac"), fallback = "Mac")
        val id = CompanionProtocol.base64Url(CompanionProtocol.randomBytes(16))
        val session = TransferSession(id)
        transferSessions[id] = session
        try {
            showTransferNotification(session, sender, files)
            if (!session.await()) {
                fail(output, "Transfer was declined or timed out")
                return
            }
            CompanionProtocol.writeEnvelope(output, org.json.JSONObject().put("op", "accepted"))
            receiveFiles(input, files)
            CompanionProtocol.writeEnvelope(output, org.json.JSONObject().put("op", "complete"))
        } finally {
            transferSessions.remove(id)
            notificationManager().cancel(transferNotificationId(id))
            ApprovalOverlay.dismiss(this, id)
        }
    }

    private fun receiveFiles(input: java.io.InputStream, files: List<CompanionProtocol.FileMeta>) {
        val resolver = contentResolver
        val staged = mutableListOf<StagedFile>()
        try {
            files.forEach { meta -> staged += stageFile(input, meta) }
            staged.forEach { it.publish() }
        } catch (error: Exception) {
            staged.forEach { file -> runCatching { resolver.delete(file.uri, null, null) } }
            throw error
        }
    }

    private data class StagedFile(val uri: android.net.Uri, val publish: () -> Unit)

    private fun stageFile(input: java.io.InputStream, meta: CompanionProtocol.FileMeta): StagedFile {
        val tree = SaveLocationStore.treeUri(this)
        return if (tree == null) stageDownload(input, meta) else stageDocument(input, meta, tree)
    }

    private fun stageDownload(input: java.io.InputStream, meta: CompanionProtocol.FileMeta): StagedFile {
        val resolver = contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, IncomingFilename.sanitize(meta.name))
            put(MediaStore.Downloads.MIME_TYPE, meta.mimeType.ifBlank { "application/octet-stream" })
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("could not create download")
        try {
            resolver.openOutputStream(uri)?.use { raw ->
                BufferedOutputStream(raw).use { destination ->
                    copyExactly(input, destination, meta.size)
                    destination.flush()
                }
            } ?: throw IllegalStateException("could not write download")
            return StagedFile(uri) {
                val published = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
                check(resolver.update(uri, published, null, null) == 1) { "could not publish download" }
            }
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
    }

    private fun stageDocument(
        input: java.io.InputStream,
        meta: CompanionProtocol.FileMeta,
        tree: android.net.Uri
    ): StagedFile {
        val resolver = contentResolver
        val parent = android.provider.DocumentsContract.buildDocumentUriUsingTree(
            tree,
            android.provider.DocumentsContract.getTreeDocumentId(tree)
        )
        val uri = android.provider.DocumentsContract.createDocument(
            resolver,
            parent,
            meta.mimeType.ifBlank { "application/octet-stream" },
            IncomingFilename.sanitize(meta.name)
        ) ?: throw IllegalStateException("could not create file in selected folder")
        try {
            resolver.openOutputStream(uri)?.use { raw ->
                BufferedOutputStream(raw).use { destination ->
                    copyExactly(input, destination, meta.size)
                    destination.flush()
                }
            } ?: throw IllegalStateException("could not write selected folder")
            return StagedFile(uri) { }
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
    }

    private fun copyExactly(input: java.io.InputStream, output: java.io.OutputStream, size: Long) {
        val buffer = ByteArray(64 * 1024)
        var remaining = size
        while (remaining > 0) {
            val count = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
            if (count <= 0) throw java.io.EOFException("truncated file")
            output.write(buffer, 0, count)
            remaining -= count
        }
    }

    private fun fail(output: java.io.OutputStream, message: String) {
        CompanionProtocol.writeEnvelope(output, org.json.JSONObject().put("op", "failure").put("message", message.take(160)))
    }

    private fun showPairingNotification(session: PairingSession, code: String) {
        val title = "Pair with ${session.macName}?"
        val detail = "Compare code $code on the Mac, then approve."
        if (ApprovalStyleStore.overlayRequested(this) && ApprovalOverlay.show(
                this, ApprovalActivity.KIND_PAIRING, session.id, title, detail, code
            )) return
        val screen = approvalScreenIntent(
            ApprovalActivity.KIND_PAIRING, session.id, title, detail, code
        )
        val notification = Notification.Builder(this, PAIRING_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_easy_share)
            .setContentTitle(title)
            .setContentText("Compare code $code, then choose an action.")
            .setStyle(Notification.BigTextStyle().bigText("Compare code $code on the Mac. Approve only if both codes match."))
            .setContentIntent(approvalPendingIntent(screen, session.id))
            .setCategory(Notification.CATEGORY_EVENT)
            .setOngoing(true)
            .setTimeoutAfter(REQUEST_TIMEOUT_MILLIS)
            .addAction(action("Approve", ACTION_APPROVE_PAIR, session.id))
            .addAction(action("Decline", ACTION_DECLINE_PAIR, session.id))
            .build()
        notificationManager().notify(pairNotificationId(session.id), notification)
    }

    private fun showTransferNotification(
        session: TransferSession,
        sender: String,
        files: List<CompanionProtocol.FileMeta>
    ) {
        val total = files.sumOf { it.size }
        val text = "${files.size} file${if (files.size == 1) "" else "s"} from $sender • ${formatBytes(total)}"
        val title = "Receive from $sender?"
        if (ApprovalStyleStore.overlayRequested(this) && ApprovalOverlay.show(
                this, ApprovalActivity.KIND_TRANSFER, session.id, title, text, null
            )) return
        val screen = approvalScreenIntent(
            ApprovalActivity.KIND_TRANSFER, session.id, title, text, null
        )
        val notification = Notification.Builder(this, TRANSFER_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_easy_share)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(approvalPendingIntent(screen, session.id))
            .setCategory(Notification.CATEGORY_EVENT)
            .setOngoing(true)
            .setTimeoutAfter(REQUEST_TIMEOUT_MILLIS)
            .addAction(action("Accept", ACTION_ACCEPT_TRANSFER, session.id))
            .addAction(action("Decline", ACTION_DECLINE_TRANSFER, session.id))
            .build()
        notificationManager().notify(transferNotificationId(session.id), notification)
    }

    private fun approvalScreenIntent(
        kind: String,
        session: String,
        title: String,
        detail: String,
        code: String?
    ) = Intent(this, ApprovalActivity::class.java).apply {
        putExtra(ApprovalActivity.EXTRA_KIND, kind)
        putExtra(ApprovalActivity.EXTRA_SESSION, session)
        putExtra(ApprovalActivity.EXTRA_TITLE, title)
        putExtra(ApprovalActivity.EXTRA_DETAIL, detail)
        code?.let { putExtra(ApprovalActivity.EXTRA_CODE, it) }
    }

    private fun approvalPendingIntent(intent: Intent, session: String): PendingIntent =
        PendingIntent.getActivity(
            this,
            ("approval" + session).hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

    private fun action(label: String, operation: String, session: String): Notification.Action {
        val intent = Intent(this, CompanionReceiverService::class.java).apply {
            action = operation
            putExtra(EXTRA_SESSION, session)
        }
        val pending = PendingIntent.getForegroundService(
            this, (operation + session).hashCode(), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Action.Builder(null, label, pending).build()
    }

    private fun readyNotification(): Notification {
        val pairing = System.currentTimeMillis() < pairingEnabledUntil
        return Notification.Builder(this, READY_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_easy_share)
            .setContentTitle("Easy Share is ready")
            .setContentText(if (pairing) "Pair new Mac is enabled for two minutes." else "Ready to receive from paired Macs.")
            .setOngoing(true)
            .addAction(action("Pair new Mac", ACTION_ENABLE_PAIRING, "ready"))
            .addAction(action("Stop", ACTION_STOP, "ready"))
            .build()
    }

    private fun updateReadyNotification() {
        if (receiving) notificationManager().notify(READY_NOTIFICATION_ID, readyNotification())
    }

    private fun createChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = notificationManager()
        manager.createNotificationChannel(NotificationChannel(READY_CHANNEL_ID, "Receiver status", NotificationManager.IMPORTANCE_LOW))
        manager.createNotificationChannel(NotificationChannel(PAIRING_CHANNEL_ID, "Pairing requests", NotificationManager.IMPORTANCE_HIGH))
        manager.createNotificationChannel(NotificationChannel(TRANSFER_CHANNEL_ID, "Transfer requests", NotificationManager.IMPORTANCE_HIGH))
    }

    private fun notificationManager() = getSystemService(NotificationManager::class.java)
    private fun deviceName(): String = PeerText.displayName(Build.MODEL, fallback = "Android")

    private fun restorePairingWindow() {
        val stored = statePreferences(this).getLong(PAIRING_UNTIL_KEY, 0)
        pairingEnabledUntil = if (stored > System.currentTimeMillis()) stored else 0
        if (pairingEnabledUntil == 0L && stored != 0L) {
            statePreferences(this).edit().putLong(PAIRING_UNTIL_KEY, 0).apply()
        }
        schedulePairingExpiry()
    }

    private fun schedulePairingExpiry() {
        pairingExpiryCallback?.let(notificationHandler::removeCallbacks)
        pairingExpiryCallback = null
        val deadline = pairingEnabledUntil
        val delay = deadline - System.currentTimeMillis()
        if (delay <= 0) return
        val callback = Runnable {
            if (pairingEnabledUntil == deadline && System.currentTimeMillis() >= deadline) {
                pairingEnabledUntil = 0
                statePreferences(this).edit().putLong(PAIRING_UNTIL_KEY, 0).apply()
                updateReadyNotification()
            }
        }
        pairingExpiryCallback = callback
        notificationHandler.postDelayed(callback, delay)
    }
    private fun describe(error: Exception): String =
        "${error.javaClass.simpleName}: ${error.message ?: "no detail"}".take(300)

    private fun recordDiagnostic(text: String) {
        statePreferences(this).edit().putString(DIAGNOSTIC_KEY, text).apply()
    }

    private fun clearDiagnostic() {
        statePreferences(this).edit().remove(DIAGNOSTIC_KEY).apply()
    }

    private class PairingSession(val id: String, val macName: String) {
        private val latch = CountDownLatch(1)
        @Volatile private var approved = false
        fun resolve(value: Boolean) { approved = value; latch.countDown() }
        fun await(): Boolean = latch.await(REQUEST_TIMEOUT_MILLIS, TimeUnit.MILLISECONDS) && approved
    }

    private class TransferSession(val id: String) {
        private val latch = CountDownLatch(1)
        @Volatile private var approved = false
        fun resolve(value: Boolean) { approved = value; latch.countDown() }
        fun await(): Boolean = latch.await(REQUEST_TIMEOUT_MILLIS, TimeUnit.MILLISECONDS) && approved
    }

    companion object {
        const val ACTION_START = "dev.easyshare.companion.action.START"
        const val ACTION_STOP = "dev.easyshare.companion.action.STOP"
        const val ACTION_ENABLE_PAIRING = "dev.easyshare.companion.action.ENABLE_PAIRING"
        const val ACTION_APPROVE_PAIR = "dev.easyshare.companion.action.APPROVE_PAIR"
        const val ACTION_DECLINE_PAIR = "dev.easyshare.companion.action.DECLINE_PAIR"
        const val ACTION_ACCEPT_TRANSFER = "dev.easyshare.companion.action.ACCEPT_TRANSFER"
        const val ACTION_DECLINE_TRANSFER = "dev.easyshare.companion.action.DECLINE_TRANSFER"
        const val EXTRA_SESSION = "session"
        private const val RECEIVING_KEY = "receiving"
        private const val PAIRING_UNTIL_KEY = "pairing-until"
        private const val DIAGNOSTIC_KEY = "diagnostic"
        private const val READY_NOTIFICATION_ID = 100
        private const val READY_CHANNEL_ID = "receiver-status"
        private const val PAIRING_CHANNEL_ID = "pairing"
        private const val TRANSFER_CHANNEL_ID = "transfer"
        private const val PAIRING_WINDOW_MILLIS = 2 * 60_000L
        private const val REQUEST_TIMEOUT_MILLIS = 2 * 60_000L
        private const val SOCKET_TIMEOUT_MILLIS = 3 * 60_000L
        private const val MAX_CONCURRENT_CONNECTIONS = 3

        fun isEnabled(context: Context): Boolean = statePreferences(context).getBoolean(RECEIVING_KEY, false)
        fun isPairingEnabled(context: Context): Boolean =
            statePreferences(context).getLong(PAIRING_UNTIL_KEY, 0) > System.currentTimeMillis()
        fun diagnostic(context: Context): String? =
            statePreferences(context).getString(DIAGNOSTIC_KEY, null)
        private fun statePreferences(context: Context) = context.getSharedPreferences("receiver-state", Context.MODE_PRIVATE)
        private fun pairNotificationId(id: String) = 1_000 + (id.hashCode() and 0x3fff)
        private fun transferNotificationId(id: String) = 20_000 + (id.hashCode() and 0x3fff)
        private fun formatBytes(bytes: Long): String = when {
            bytes < 1024 -> "$bytes B"
            bytes < 1024 * 1024 -> "${bytes / 1024} KB"
            bytes < 1024 * 1024 * 1024 -> "${bytes / (1024 * 1024)} MB"
            else -> "${bytes / (1024 * 1024 * 1024)} GB"
        }
    }
}
