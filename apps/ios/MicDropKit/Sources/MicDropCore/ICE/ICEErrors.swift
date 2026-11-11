import Foundation

/// A violation of the ICE wire contract or of a local ICE invariant.
///
/// Kotlin throws `IllegalArgumentException` / `IllegalStateException` with these fixed texts (`TrickleIce.kt`,
/// `ContinuousIce.kt`, `StreamReceiver.kt:1568-1646`). Classifies every `ICEProtocolError` as non-retryable:
/// `SETUP_FAILED` / `session_exception`. `message` is a fixed label and never contains SDP, candidates, credentials or
/// addresses. User-visible text is never derived from it.
public struct ICEProtocolError: Error, Hashable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) { self.message = message }
    public init(message: String) { self.message = message }

    public var description: String { message }

    // `ICEDescription.parse` (`TrickleIce.kt:94-125`).
    public static let invalidDescription = ICEProtocolError("Invalid ICE description")
    public static let sectionLimit = ICEProtocolError("ICE section limit")
    public static let sectionsUnavailable = ICEProtocolError("ICE sections unavailable")
    public static let invalidTransport = ICEProtocolError("Invalid ICE transport")
    public static let invalidCandidate = ICEProtocolError("Invalid ICE candidate")

    // `TrickleExchange` (`TrickleIce.kt:30-70`, `StreamReceiver.kt:1623-1633`).
    public static let generationChanged = ICEProtocolError("ICE generation changed")
    public static let candidateLimit = ICEProtocolError("ICE candidate limit")
    public static let invalidUpdate = ICEProtocolError("Invalid ICE update")
    public static let conflictingUpdate = ICEProtocolError("Conflicting ICE update")
    public static let invalidCompletion = ICEProtocolError("Invalid ICE completion")
    public static let candidateRejected = ICEProtocolError("ICE candidate rejected")
    public static let invalidGeneration = ICEProtocolError("Invalid ICE generation")
    public static let batchLimit = ICEProtocolError("ICE batch limit")
    /// The phone attached `ice`/`continuous_ice` but the `/status` reply lacks the matching object (Kotlin
    /// `getJSONObject` failure, `StreamReceiver.kt:658-659`).
    public static let missingUpdate = ICEProtocolError("Missing ICE update")

    // `ContinuousExchange` (`ContinuousIce.kt:21-69`, `StreamReceiver.kt:1635-1646`).
    public static let snapshotLimit = ICEProtocolError("ICE snapshot limit")
    public static let invalidSnapshot = ICEProtocolError("Invalid ICE snapshot")
    public static let duplicateCandidate = ICEProtocolError("Duplicate ICE candidate")
    public static let revisionLimit = ICEProtocolError("ICE revision limit")
    public static let missingSnapshot = ICEProtocolError("Missing ICE snapshot")
    public static let conflictingSnapshot = ICEProtocolError("Conflicting ICE snapshot")
    public static let removalRejected = ICEProtocolError("ICE removal rejected")

    // `ContinuousCandidateEvidence` (`ContinuousIce.kt:226`).
    public static let evidenceLimit = ICEProtocolError("ICE evidence limit")

    // restart invariants (`LanRecovery.kt:109,128`, `StreamReceiver.kt:1600`).
    public static let credentialsNotRenewed = ICEProtocolError("ICE credentials were not renewed")
    public static let restartNotDue = ICEProtocolError("ICE restart not due")
    public static let recoveryNotPending = ICEProtocolError("ICE recovery not pending")

    /// steps 9-12: a `/v1/ice` body that violates a validation rule. Android throws
    /// `IllegalArgumentException`/`JSONException` (`RemoteIce.kt:296-323`); classified exactly like
    /// `ControlResponseError(.invalidICE)` (non-retryable `SETUP_FAILED`).
    public static let invalidConfiguration = ICEProtocolError("Invalid ICE configuration")
}

/// The media-recovery window expired, or a restart could not yet prove fresh candidates (Kotlin
/// `java.net.SocketTimeoutException`, `LanRecovery.kt:118`, `StreamReceiver.kt:1604`).
///
/// an I/O-timeout class error — retryable (`retryableStatus == true`), `describe` code `TIMEOUT`, `SessionFailure`
/// `stage_timeout`. The status loop then fails the session itself once `LanRecovery.expired(now)` (step 6).
public struct RecoveryTimeout: Error, Hashable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) { self.message = message }
    public init(message: String) { self.message = message }

    public var description: String { message }

    /// `LanRecovery.exchangeStatus` deadline check (`LanRecovery.kt:118`).
    public static let deadlineReached = RecoveryTimeout("Media recovery deadline reached")
    /// Non-continuous restart whose gathering cannot submit yet (`StreamReceiver.kt:1604`).
    public static let candidatesUnavailable = RecoveryTimeout("Recovery candidates unavailable")
}
