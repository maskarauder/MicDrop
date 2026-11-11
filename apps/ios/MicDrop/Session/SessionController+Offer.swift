import Foundation
import MicDropCore

/// `POST /offer` with the previous-Stop retry and the 423 busy retry (`StreamReceiver.kt:1203-1232`).
extension SessionController {

    /// `obtainOffer()` (`StreamReceiver.kt:1203-1232`).
    ///
    /// 1. `SessionStopRetry.beforeOffer`: an unacknowledged Stop of the previous session to the same
    ///    destination (≤ 120 s old) is sent first with its old token (cancellable; 401/410 count as
    ///    done inside `SessionStopRetry`; any other failure aborts this Connect).
    /// 2. `BusyOfferRetry(enabled: reconnect || previousStop)`: only an explicit 423 within 5 s is
    ///    retried, every 500 ms (interruptible), with the same nonce. Ambiguous failures are never
    ///    retried (an offer may have been allocated).
    /// 3. Duplex + 400 → `duplexUnsupported` / `mode_not_confirmed`; microphone modes + 409 →
    ///    `microphoneReturnNotConfigured` / `host_microphone_gate`; then rethrow.
    func obtainOffer() throws -> ControlJSON {
        let previousStop = try SessionStopRetry.shared.beforeOffer(destination: stopDestination, nowMs: nowMs()) {
            stop in
            self.emitStatus(Messages.finishingPreviousSession)
            _ = try self.request(
                "/stop", token: stop.token, body: WireBody.stop(reason: stop.reason),
                timeoutMs: self.stopTimeoutMs)
        }
        func busyRetry(_ enabled: Bool) -> BusyOfferRetry {
            BusyOfferRetry(
                enabled: enabled, startedMs: nowMs(),
                limitMs: Int64(configuration.connectionPreferences[.busyHost]))
        }
        var retry = busyRetry(configuration.reconnect || previousStop)
        var cancelledForFallback = false
        while !isClosed {
            do {
                iceConfiguration = try fetchRemoteICEConfiguration()
                let fields = try mode.offerFields(version: protocolVersion).map { ($0.0, WireValue.int($0.1)) }
                offerAttempt.begin()
                return try request(
                    "/offer", token: configuration.link.token, body: WireBody.object(fields),
                    timeoutMs: configuration.connectionPreferences[.initialOffer])
            } catch is OfferFallbackRequired {
                guard !cancelledForFallback else { throw SignalingRoutesUnavailable() }
                try workerWait.checkpoint()
                let acknowledgment = try transportRequest(
                    "/cancel-offer", token: configuration.link.token, body: WireBody.version(protocolVersion),
                    timeoutMs: configuration.connectionPreferences[.cancelOffer], direct: signalingRoute.direct)
                try offerAttempt.cancelledForFallback(acknowledged: acknowledgment.bool("offer_cancelled"))
                cancelledForFallback = true
                retry = busyRetry(true)
            } catch let failure as HTTPFailure {
                if mode == .duplex && failure.status == 400 {
                    fail(Messages.duplexUnsupported, code: .modeNotConfirmed)
                    throw failure
                }
                if microphoneReturn && failure.status == 409 {
                    fail(Messages.microphoneReturnNotConfigured, code: .hostMicrophoneGate)
                    throw failure
                }
                // Only an explicit 423 proves no new session was allocated.
                guard retry.allow(status: failure.status, nowMs: nowMs()) else { throw failure }
                try workerWait.sleep(ms: Timing.busyRetrySpacingMs)
            }
        }
        throw SessionStopped()
    }
}
