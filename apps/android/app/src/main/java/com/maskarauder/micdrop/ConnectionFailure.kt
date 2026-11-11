package com.maskarauder.micdrop

import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.security.cert.CertificateExpiredException
import java.security.cert.CertificateNotYetValidException
import java.util.concurrent.TimeoutException
import javax.net.ssl.SSLException

internal enum class ConnectionStage(val label: String) {
    WAITING("Waiting for the previous session to stop"),
    PAIRING("Connecting securely to Windows"),
    AUDIO("Initializing Android audio"),
    CODEC("Selecting Opus"),
    OFFER("Applying the Windows offer"),
    ANSWER("Creating the stereo answer"),
    ROUTES("Gathering local network routes"),
    SUBMITTING("Sending the answer to Windows"),
    PLAYBACK("Receiving audio"),
    INPUT_ROUTE("Selecting microphone input"),
    MICROPHONE("Sending phone microphone")
}

internal class HttpFailure(val status: Int) : IOException()
internal class PairingKeyUpgradeRequired : java.security.GeneralSecurityException()
// These error types stay platform-independent with the shared failure mapper,
// which is also compiled by the isolated pairing contract APK.
internal enum class MicrophoneRouteProblem(val detail: String) {
    BLUETOOTH_PERMISSION("Allow Nearby devices permission for MicDrop to identify and recover your selected headset. You can still use the phone or a wired microphone without it."),
    UNAVAILABLE("The selected microphone is unavailable. Tap Microphone input, choose a connected input and start again."),
    IN_USE("Android is already in a call or communication mode. End that session before selecting a Bluetooth microphone."),
    UNVERIFIED("Android could not verify the selected microphone route. Check the headset connection, choose an available input and start again."),
    LE_STEREO_UNAVAILABLE("Android could not provide verified stereo output on the selected LE Audio headset. Turn off LE Audio stereo playback to try mono compatibility, or choose the phone microphone for media playback.")
}
internal class MicrophoneRouteException(val problem: MicrophoneRouteProblem) : Exception()

internal object ConnectionFailure {
    fun retryableStatus(error: Throwable, establishedSession: Boolean = false): Boolean {
        val causes = generateSequence(error) { it.cause }.take(8).toList()
        if (causes.any { it is OfferFallbackRequired || it is InterruptedException }) return false
        if (causes.any { it is SSLException || it is java.security.cert.CertificateException }) return false
        val http = causes.filterIsInstance<HttpFailure>().firstOrNull()
        if (http != null) return http.status in listOf(429, 500, 502, 503, 504)
        // Exhausting both routes ends initial setup. An established session may
        // retry its idempotent control operations within its original deadline,
        // even before Android publishes a default-network change.
        if (causes.any { it is SignalingRoutesUnavailable }) return establishedSession
        return causes.any { it is IOException }
    }

    fun describe(stage: ConnectionStage, error: Throwable, reconnectAction: String = "Reconnect"): String {
        // Inspect types only. Exception messages may contain URLs, SDP, or
        // credentials, so neither the UI nor logcat receives those messages.
        val causes = generateSequence(error) { it.cause }.take(8).toList()
        val http = causes.filterIsInstance<HttpFailure>().firstOrNull()
        val tls = causes.filterIsInstance<SignalingTlsFailure>().firstOrNull()
        val (code, detail) = when {
            causes.any { it is SignalingRoutesUnavailable } -> "SIGNALING_UNAVAILABLE" to
                "The control request could not complete through rendezvous or direct LAN. Copy the session report, then tap $reconnectAction."
            causes.any { it is MicrophoneRouteException } -> "MICROPHONE_ROUTE" to
                causes.filterIsInstance<MicrophoneRouteException>().first().problem.detail
            stage == ConnectionStage.INPUT_ROUTE -> "MICROPHONE_ROUTE" to MicrophoneRouteProblem.UNVERIFIED.detail
            causes.any { it is PairingKeyUpgradeRequired } || tls?.problem == TlsProblem.KEY_UPDATE -> "PAIRING_KEY_UPDATE" to
                "This phone identity was created by an older build without TLS signing support. Tap Forget saved connection, then paste a new Windows pairing invitation and tap Connect."
            http != null -> "HTTP_${http.status}" to when (http.status) {
                401 -> "The connection link was rejected. Paste a new invitation from the running Windows host."
                403 -> "This phone is not approved on Windows, or its pairing was revoked. In the Windows app, open Phones → Pair a phone and pair again."
                409, 410 -> "The session or link has ended. Use $reconnectAction if the link is still valid; otherwise restart Windows and paste its new link."
                423 -> "Windows already has an active session or is finishing one. Stop it or wait for its timeout, then tap $reconnectAction. It can take up to 45 seconds after interrupted setup."
                400 -> "Windows rejected a connection request. Copy the session report and check that both apps are up to date."
                429, 503 -> "Windows is busy. Wait briefly, then try connecting again."
                else -> "Windows could not complete this request. Check the Windows console, then try $reconnectAction."
            }
            causes.any { it is CertificateExpiredException || it is CertificateNotYetValidException } || tls?.problem == TlsProblem.CERTIFICATE_TIME ->
                "CERTIFICATE_TIME" to "A secure connection certificate is outside its validity period. Check device clocks and the server certificate, then try connecting again."
            tls?.problem == TlsProblem.IDENTITY || causes.any { it is java.security.cert.CertificateException || it is javax.net.ssl.SSLPeerUnverifiedException } ->
                "TLS_IDENTITY" to "The secure connection identity could not be verified. Check the saved connection and server certificate before trying again."
            causes.any { it is SSLException } ->
                "TLS_CONNECTION" to "The secure signaling connection failed. Copy the last stream report for details, then try reconnecting."
            causes.any { it is SignalingStreamEnded } ->
                "NETWORK_IO" to "The secure signaling connection was interrupted. Check network access and try reconnecting."
            causes.any { it is ConnectException || it is NoRouteToHostException } ->
                "HOST_UNREACHABLE" to "Cannot reach Windows. Check the displayed IP, the running host, Wi-Fi, and the Windows private-network firewall rule."
            causes.any { it is SocketTimeoutException || it is TimeoutException } ->
                "TIMEOUT" to if (stage == ConnectionStage.PAIRING)
                    "Windows did not respond in time. Check its IP, Wi-Fi/client isolation, and firewall, then try connecting again."
                else "This connection stage timed out. Check the Windows console and try connecting again."
            causes.any { it is LinkageError } ->
                "NATIVE_LOAD" to "The native audio library could not load. Reinstall the latest Android arm64 APK."
            causes.any { it is IOException } ->
                "NETWORK_IO" to "The network connection stopped. Check the Windows host and network access, then try connecting again."
            else -> "SETUP_FAILED" to "Audio connection setup failed. Report this stage and code, and the Windows console result, without the invitation."
        }
        val label = if (causes.any { it is SignalingRoutesUnavailable }) "Connection control"
            else if (tls != null || causes.any { it is SSLException || it is SignalingStreamEnded }) "Secure signaling" else stage.label
        return "$label failed [$code].\n$detail"
    }
}
