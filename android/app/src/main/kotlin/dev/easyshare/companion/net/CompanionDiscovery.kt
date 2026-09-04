package dev.easyshare.companion.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import dev.easyshare.companion.crypto.CompanionIdentity

/**
 * Registers only after the TLS listener has chosen its actual port. Registration
 * is process-wide because NsdManager unregistration is asynchronous: a rapid
 * receiver off/on must wait for the old advertisement to disappear before it
 * publishes the replacement.
 */
class CompanionDiscovery(private val context: Context) {
    private val owner = Any()

    fun register(port: Int, displayName: String) {
        val fingerprint = CompanionIdentity.fingerprintHex(context)
        val info = NsdServiceInfo().apply {
            // A stable name lets Bonjour replace a receiver cleanly instead of
            // presenting EasyShare-xxxx, EasyShare-xxxx (2), and so on.
            serviceName = "EasyShare-${fingerprint.take(12)}"
            serviceType = SERVICE_TYPE
            this.port = port
            setAttribute("v", CompanionProtocol.version.toString())
            setAttribute("n", CompanionProtocol.base64Url(displayName.toByteArray(Charsets.UTF_8)))
            setAttribute("fp", fingerprint)
        }
        Registry.register(owner, context.applicationContext, info)
    }

    fun unregister() = Registry.unregister(owner)

    companion object {
        const val SERVICE_TYPE = "_easyshare-companion._tcp."
    }

    private object Registry {
        private val lock = Any()
        private var nsd: NsdManager? = null
        private var activeListener: NsdManager.RegistrationListener? = null
        private var activeOwner: Any? = null
        private var pending: PendingRegistration? = null
        private var unregistering = false

        private data class PendingRegistration(val owner: Any, val info: NsdServiceInfo)

        fun register(owner: Any, context: Context, info: NsdServiceInfo) = synchronized(lock) {
            nsd = context.getSystemService(NsdManager::class.java)
            pending = PendingRegistration(owner, info)
            when {
                activeListener == null && !unregistering -> registerPendingLocked()
                activeOwner !== owner && !unregistering -> unregisterActiveLocked()
            }
        }

        fun unregister(owner: Any) = synchronized(lock) {
            if (pending?.owner === owner) pending = null
            // A previous service instance may receive a delayed onDestroy after
            // the user has already started a fresh receiver. It must never tear
            // down the new instance's Bonjour record.
            if (activeOwner === owner && activeListener != null && !unregistering) {
                unregisterActiveLocked()
            }
        }

        private fun registerPendingLocked() {
            val manager = nsd ?: return
            val registration = pending ?: return
            pending = null
            val listener = object : NsdManager.RegistrationListener {
                override fun onServiceRegistered(serviceInfo: NsdServiceInfo) = Unit

                override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    synchronized(lock) {
                        if (activeListener === this) {
                            activeListener = null
                            activeOwner = null
                        }
                        // A superseding receiver request may have arrived while
                        // this registration was in flight.
                        if (!unregistering) registerPendingLocked()
                    }
                }

                override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {
                    synchronized(lock) {
                        if (activeListener === this) {
                            activeListener = null
                            activeOwner = null
                        }
                        unregistering = false
                        registerPendingLocked()
                    }
                }

                override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    synchronized(lock) {
                        if (activeListener === this) {
                            activeListener = null
                            activeOwner = null
                        }
                        unregistering = false
                        registerPendingLocked()
                    }
                }
            }
            activeListener = listener
            activeOwner = registration.owner
            runCatching { manager.registerService(registration.info, NsdManager.PROTOCOL_DNS_SD, listener) }
                .onFailure {
                    if (activeListener === listener) {
                        activeListener = null
                        activeOwner = null
                    }
                    registerPendingLocked()
                }
        }

        private fun unregisterActiveLocked() {
            val manager = nsd ?: return
            val listener = activeListener ?: return
            unregistering = true
            runCatching { manager.unregisterService(listener) }
                .onFailure {
                    if (activeListener === listener) {
                        activeListener = null
                        activeOwner = null
                    }
                    unregistering = false
                    registerPendingLocked()
                }
        }
    }
}
