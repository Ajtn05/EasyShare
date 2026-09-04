package dev.easyshare.companion.crypto

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.math.BigInteger
import java.security.KeyStore
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.Date
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.security.auth.x500.X500Principal

/**
 * The companion has exactly one local TLS identity. A Mac stores its
 * certificate fingerprint only after the user compares the pairing code on
 * both devices; regular sends never fall back to platform certificate trust.
 */
object CompanionIdentity {
    // v3 intentionally replaces the initial test identities. Android's own
    // KeyGenParameterSpec documentation notes that TLS server keys generally
    // need DIGEST_NONE and RSA decryption paddings because Conscrypt performs
    // some TLS operations itself rather than through Signature. Restricting
    // the key to application-level signing caused the server to abort before
    // sending its certificate on this Android 16 device.
    private const val alias = "dev.easyshare.companion.tls.v3"

    @Synchronized
    fun tlsContext(context: Context): SSLContext {
        ensureIdentity(context)
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val keyManagers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).run {
            init(store, null)
            keyManagers
        }
        return SSLContext.getInstance("TLS").apply {
            init(keyManagers, null, SecureRandom())
        }
    }

    @Synchronized
    fun certificate(context: Context): X509Certificate {
        ensureIdentity(context)
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        return store.getCertificate(alias) as X509Certificate
    }

    fun fingerprintHex(context: Context): String = certificate(context).encoded.sha256Hex()

    private fun ensureIdentity(context: Context) {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (store.containsAlias(alias)) return

        val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore")
        val now = System.currentTimeMillis()
        generator.initialize(
            KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY or KeyProperties.PURPOSE_DECRYPT
            )
                .setKeySize(2048)
                .setDigests(
                    KeyProperties.DIGEST_NONE,
                    KeyProperties.DIGEST_SHA256,
                    KeyProperties.DIGEST_SHA384,
                    KeyProperties.DIGEST_SHA512
                )
                .setSignaturePaddings(
                    KeyProperties.SIGNATURE_PADDING_RSA_PKCS1,
                    KeyProperties.SIGNATURE_PADDING_RSA_PSS
                )
                .setEncryptionPaddings(
                    KeyProperties.ENCRYPTION_PADDING_NONE,
                    KeyProperties.ENCRYPTION_PADDING_RSA_PKCS1
                )
                .setRandomizedEncryptionRequired(false)
                .setCertificateSubject(X500Principal("CN=Easy Share Companion"))
                .setCertificateSerialNumber(BigInteger(64, SecureRandom()))
                .setCertificateNotBefore(Date(now - 60_000))
                .setCertificateNotAfter(Date(now + 10L * 365 * 24 * 60 * 60 * 1000))
                .build()
        )
        generator.generateKeyPair()
    }

    fun ByteArray.sha256Hex(): String = MessageDigest.getInstance("SHA-256").digest(this)
        .joinToString(separator = "") { "%02x".format(it) }
}
