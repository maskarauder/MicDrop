package com.maskarauder.micdrop

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.net.URI
import java.io.FileNotFoundException
import java.security.KeyStore
import java.text.DateFormat
import java.util.Date
import java.util.concurrent.Executors
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

internal data class SavedConnectionView(val message: String = "Loading saved connection…",
    val available: Boolean = false, val present: Boolean = false, val working: Boolean = true,
    val pairing: Boolean = false, val paired: Boolean = false, val needsForget: Boolean = false,
    val pairingFailureId: Long = 0, val pairingSuccessId: Long = 0)

// One process-wide queue serializes Keystore and AtomicFile operations. UI state
// and observer callbacks stay on main; no Activity or service is retained by IO.
internal class SavedConnections private constructor(context: Context) {
    private val applicationContext = context.applicationContext
    private val file = AtomicFile(File(context.noBackupFilesDir, "last-connection.bin"))
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val observers = mutableSetOf<(SavedConnectionView) -> Unit>()
    private var link: String? = null
    private var revision = 0L
    private var view = SavedConnectionView()
    private var pairingAttempt: PairingAttempt? = null

    init { load() }

    fun observe(observer: (SavedConnectionView) -> Unit) { observers.add(observer); observer(view) }
    fun removeObserver(observer: (SavedConnectionView) -> Unit) { observers.remove(observer) }

    fun connection(): String? {
        if (view.working) return null
        val saved = link ?: return null
        if (LanInvitation.parse(saved).expired()) {
            publish(savedView(saved)); return null
        }
        return saved
    }

    private fun publish(next: SavedConnectionView) {
        view = next
        observers.toList().forEach { it(next) }
    }

    private fun savedView(text: String): SavedConnectionView {
        val invitation = LanInvitation.parse(text)
        if (invitation.version == 3) return SavedConnectionView(
            "Paired Windows: ${invitation.remote?.let { "remote via ${URI(it.url).host}" } ?: "${invitation.host}:${invitation.port}"}\nSaved for this phone. Connect uses the audio and microphone options below.",
            available = true, present = true, working = false, paired = true)
        val expiry = DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT)
            .format(Date(invitation.expiresAt * 1000))
        return SavedConnectionView("Saved Windows: ${invitation.host}:${invitation.port}\n" +
            if (invitation.expired()) "Link expired. Paste a new Windows link." else "Link expires $expiry. Connect uses the audio options below.",
            available = !invitation.expired(), present = true, working = false)
    }

    private fun keyStore() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private fun key(create: Boolean): SecretKey {
        val existing = keyStore().getKey(ALIAS, null)
        if (existing is SecretKey) return existing
        check(create)
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }

    private fun readLink(): String {
        val bytes = file.openRead().use { input ->
            val buffer = ByteArray(ConnectionEnvelope.MAX_BYTES + 1)
            var count = 0
            while (count < buffer.size) {
                val read = input.read(buffer, count, buffer.size - count)
                if (read < 0) break
                count += read
            }
            buffer.copyOf(count)
        }
        return ConnectionEnvelope.open(bytes, key(false))
    }

    private fun load() {
        val operation = ++revision
        worker.execute {
            var loaded: String? = null
            val result = try {
                loaded = readLink() // openRead also performs AtomicFile recovery.
                validateSaved(loaded)
                savedView(loaded)
            } catch (_: FileNotFoundException) {
                loaded = null
                if (file.baseFile.exists()) SavedConnectionView("Saved connection could not be read. Tap Forget and connect again.", present = true, working = false, needsForget = true)
                else SavedConnectionView("No saved connection. Paste a Windows link.",
                    present = try { AndroidIdentity.exists() } catch (_: Exception) { true }, working = false)
            } catch (_: PairingKeyUpgradeRequired) {
                loaded = null
                SavedConnectionView("Phone pairing key needs updating. Tap Forget saved connection, then connect with a new Windows pairing invitation.",
                    present = true, working = false, needsForget = true)
            } catch (_: Exception) {
                loaded = null
                SavedConnectionView("Saved connection or phone identity could not be read. Tap Forget before pairing again.", present = true, working = false, needsForget = true)
            }
            val saved = loaded
            main.post { if (operation == revision) { link = saved; publish(result) } }
        }
    }

    // Called only after the stream first reaches Playing. A rejected link never
    // replaces the last successful one. Legacy v1 links are intentionally unsaved.
    fun remember(text: String) {
        if (LanInvitation.parse(text).version < 2 || pairingAttempt != null) return
        val normalized = text.trim()
        if (link == normalized && !view.working) return
        val operation = ++revision
        publish(view.copy(working = true))
        worker.execute {
            val saved = try {
                writeLink(normalized)
                true
            } catch (_: Exception) { false }
            main.post {
                if (operation != revision) return@post
                if (saved) { link = normalized; publish(savedView(normalized)) }
                else publish(view.copy(message = "Playback connected, but saving could not be confirmed. Reconnect still uses the previous entry in this app session.", working = false))
            }
        }
    }

    fun forget() {
        pairingAttempt?.cancel(); pairingAttempt = null
        val operation = ++revision
        link = null
        publish(SavedConnectionView("Forgetting saved connection…"))
        worker.execute {
            val removed = try {
                keyStore().deleteEntry(ALIAS)
                AndroidIdentity.forget()
                RemoteIce.clear()
                file.delete()
                check(!file.baseFile.exists())
                true
            } catch (_: Exception) { false }
            main.post {
                if (operation != revision) return@post
                publish(SavedConnectionView(if (removed) applicationContext.getString(R.string.connection_forgotten)
                    else "Could not confirm removal. Tap Forget again.", present = !removed, working = false))
            }
        }
    }

    private fun validateSaved(text: String) {
        val connection = LanInvitation.parse(text)
        require(connection.version >= 2)
        if (connection.version == 3) AndroidIdentity.manager(connection.clientKey)
    }

    private fun writeLink(text: String) {
        validateSaved(text)
        val bytes = ConnectionEnvelope.seal(text, key(true))
        val stream = file.startWrite()
        try { stream.write(bytes); file.finishWrite(stream) }
        catch (error: Exception) { file.failWrite(stream); throw error }
        // AtomicFile may report sync/rename failures only through logcat.
        check(readLink() == text)
    }

    fun pair(text: String, label: String): Long? {
        if (view.working) return null
        if (view.needsForget) {
            publish(view.copy(message = "The saved connection or identity is unreadable. Tap Forget before pairing again.",
                pairingFailureId = ++revision)); return null
        }
        val invitation = PairingInvitation.parse(text)
        require(!invitation.expired())
        val previous = link
        val operation = ++revision
        val attempt = PairingAttempt(); pairingAttempt = attempt
        publish(view.copy(message = "Connecting securely to Windows for pairing…", working = true, pairing = true,
            pairingFailureId = 0, pairingSuccessId = 0))
        worker.execute {
            var record: String? = null
            var failed = false
            var message = applicationContext.getString(R.string.pairing_cancelled)
            try {
                attempt.check()
                previous?.let { validateSaved(it) } // Missing paired keys require explicit Forget, never silent replacement.
                val identity = AndroidIdentity.ensure()
                val connection = PairingClient.enroll(applicationContext, invitation, identity, label, attempt) { progress -> main.post {
                    if (operation == revision && !attempt.cancelled.get()) publish(view.copy(message = progress))
                } }
                attempt.check()
                val value = connection.pairedRecord()
                writeLink(value)
                record = value
            } catch (_: InterruptedException) {
                Thread.interrupted()
            } catch (error: Exception) {
                failed = true
                message = if (error is PairingKeyUpgradeRequired)
                    ConnectionFailure.describe(ConnectionStage.PAIRING, error)
                else if (error is HttpFailure && error.status in listOf(409, 410))
                    applicationContext.getString(R.string.pairing_window_ended)
                else ConnectionFailure.describe(ConnectionStage.PAIRING, error) +
                    "\n" + applicationContext.getString(R.string.pairing_not_saved)
            } finally { attempt.thread = null }
            val completed = record
            main.post {
                if (operation != revision) return@post
                pairingAttempt = null
                if (completed != null) {
                    link = completed
                    publish(savedView(completed).copy(pairingSuccessId = if (!attempt.cancelled.get()) operation else 0))
                }
                else publish((previous?.let { savedView(it) } ?: SavedConnectionView(present = true, working = false))
                    .copy(message = message, pairingFailureId = if (failed && !attempt.cancelled.get()) operation else 0))
            }
        }
        return operation
    }

    fun cancelPairing() {
        pairingAttempt?.cancel()
        publish(view.copy(message = "Cancelling pairing…"))
    }

    fun updateAddress(host: String, port: Int) {
        val previous = connection() ?: return
        val current = LanInvitation.parse(previous)
        require(current.version == 3)
        remember(LanInvitation.paired(host, port, PublicIdentity.hex(current.fingerprint), current.clientKey, current.remote).pairedRecord())
    }

    companion object {
        private const val ALIAS = "micdrop.saved-connection.v1"
        @Volatile private var instance: SavedConnections? = null
        fun get(context: Context): SavedConnections = instance ?: synchronized(this) {
            instance ?: SavedConnections(context.applicationContext).also { instance = it }
        }
    }
}
