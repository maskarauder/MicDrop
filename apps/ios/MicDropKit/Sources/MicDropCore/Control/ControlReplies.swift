import Foundation

// Strict checks of the small control replies. Each failed Kotlin `check`/`require`/`get*` is a non-retryable
// `ControlResponseError(.invalidReply)` (`SETUP_FAILED`, `session_exception`).
extension ControlJSON {
    /// `/microphone`: `ok == true && muted is a JSON boolean && muted == requested`
    /// (`A/StreamReceiver.kt:1339`).
    public func requireMicrophoneAck(muted: Bool) throws {
        guard bool("ok"), isBool("muted"), bool("muted") == muted else {
            throw ControlResponseError(.invalidReply)
        }
    }

    /// `/recover-offer`: `version == 3 && generation == G` (`check`), `1 ≤ sdp.length ≤ 65536`
    /// (`require`, UTF-16 units). Returns the recovery offer SDP (`A/StreamReceiver.kt:1587-1589`).
    public func requireRecoveryOffer(generation: Int64) throws -> String {
        guard try requireInt("version") == 3, try requireInt64("generation") == generation else {
            throw ControlResponseError(.invalidReply)
        }
        let sdp = try requireString("sdp")
        let length = sdp.utf16.count
        guard length >= 1, length <= OfferCapabilities.maxSDPLength else {
            throw ControlResponseError(.invalidReply)
        }
        return sdp
    }

    /// `/recover-answer`: `ok == true && generation == G` (`A/StreamReceiver.kt:1619`).
    public func requireRecoveryAnswerAck(generation: Int64) throws {
        guard bool("ok"), try requireInt64("generation") == generation else {
            throw ControlResponseError(.invalidReply)
        }
    }

    /// `/cancel-offer`: `offer_cancelled` (`optBoolean`, default false, `A/StreamReceiver.kt:850`).
    public var offerCancelled: Bool {
        bool("offer_cancelled", default: false)
    }

    /// `/stop`: `receiver_diagnostics` (`optString`, default `not confirmed`, `A/StreamReceiver.kt:841`).
    public var receiverDiagnostics: String {
        string("receiver_diagnostics", default: "not confirmed")
    }
}
