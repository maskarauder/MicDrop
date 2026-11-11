import Foundation

/// One control-plane request. The transport (`LanControlTransport`, `RemoteControlTransport`, MicDropTransport) turns
/// it into exactly the HTTP/1.0 bytes: `GET` iff `body == nil`, `Authorization: Bearer <bearer>` iff `bearer != nil`,
/// `X-MicDrop-Offer-Attempt` iff `offerAttempt != nil`, `X-MicDrop-Phone-Control: 1` iff `phoneControlOffer`,
/// `X-MicDrop-Session-Resume: 1` iff `sessionResume`, both ICE headers iff `trickleHeaders`,
/// `Content-Type`/`Content-Length` for POST. Preconditions are validated by the transport before any I/O; the pure
/// predicates live here (`pathIsValid`, `credentialIsValid`).
public struct ControlRequest: Sendable, Equatable {
    /// `^/[a-z-]+$`, no query string (host 400, `internal/session/limits.go:26`).
    public let path: String
    /// nil or a 43-char base64url credential; never for `/pair`, v3 `/offer`, v3 `/cancel-offer`.
    public let bearer: String?
    /// Only `/offer` and `/cancel-offer` (`A/OfferAttempt.kt:14-16`).
    public let offerAttempt: String?
    /// Remote v3 `/offer` only (`A/StreamReceiver.kt:1663-1664`).
    public let trickleHeaders: Bool
    /// Paired `/offer` only. Older hosts ignore the requested windows; the reply must confirm v1.
    public let connectionPreferences: ConnectionPreferences?
    /// Compact UTF-8 JSON object, ≤ `bodyBudget`; nil → GET.
    public let body: Data?
    /// Response body cap, ≤ `bodyBudget`; `/pair` uses `pairResponseLimit`.
    public var maxResponseBytes: Int
    /// v3 `/offer` only (`PhoneControl.offerHeader`): asks the host for phone settings exchange v1. Sent whatever
    /// the local opt-in says; the snapshot reports that state (`A/PhoneControl.kt:84`).
    public let phoneControlOffer: Bool
    /// The host confirmed phone control for this session. Only `/status` then gets the larger body budget
    /// (`bodyLimit(path:negotiated:)`); every other path keeps 96 KiB.
    public let phoneControlNegotiated: Bool
    /// v3 `/offer` only (`SessionResume.offerHeader`): a presentation hint for an intentional Play/resume or
    /// input-switch replacement. It grants no consent and carries no capability.
    public let sessionResume: Bool
    /// v3 `/offer` only (`SessionResume.reasonHeader`), paired with `sessionResume`: `manual`, `automatic` or
    /// `focus_regain`.
    public let sessionResumeReason: SessionResume.Reason?

    /// Default request and response body bound, 96 KiB (`A/RemoteHttp.kt:46,65`).
    public static let maxBodyBytes = 98_304
    /// Negotiated phone-control `/status` bound: 96 KiB plus the 64 KiB settings allowance
    /// (`A/PhoneControl.kt:82-83`; host `server.go:294-300`).
    public static let phoneControlBodyBytes = maxBodyBytes + PhoneControl.maxBodyBytes
    /// `/pair` reply cap for LAN and remote.
    public static let pairResponseLimit = 1_024
    /// A `/stop` that carried terminal `diagnostics` and failed with one of these statuses is resent once without them
    /// (`A/StreamReceiver.kt:833-839`).
    public static let stopDiagnosticsRejectStatuses: Set<Int> = [400, 413, 422]

    /// `maxResponseBytes == nil` uses `bodyBudget`. New parameters are appended last so existing call sites keep
    /// their meaning and every header flag defaults to off.
    public init(
        path: String, bearer: String? = nil, offerAttempt: String? = nil,
        trickleHeaders: Bool = false, body: Data? = nil,
        maxResponseBytes: Int? = nil,
        connectionPreferences: ConnectionPreferences? = nil,
        phoneControlOffer: Bool = false, phoneControlNegotiated: Bool = false,
        sessionResume: Bool = false, sessionResumeReason: SessionResume.Reason? = nil
    ) {
        self.path = path
        self.bearer = bearer
        self.offerAttempt = offerAttempt
        self.trickleHeaders = trickleHeaders
        self.connectionPreferences = connectionPreferences
        self.body = body
        self.phoneControlOffer = phoneControlOffer
        self.phoneControlNegotiated = phoneControlNegotiated
        self.sessionResume = sessionResume
        self.sessionResumeReason = sessionResumeReason
        self.maxResponseBytes =
            maxResponseBytes ?? ControlRequest.bodyLimit(path: path, negotiated: phoneControlNegotiated)
    }

    /// `GET` when there is no body, else `POST` (rule 2).
    public var method: String { body == nil ? "GET" : "POST" }

    /// The request-body and response-body bound of this request: `bodyLimit(path:negotiated:)`.
    public var bodyBudget: Int { ControlRequest.bodyLimit(path: path, negotiated: phoneControlNegotiated) }

    /// `PhoneControlSession.bodyLimit` (`A/PhoneControl.kt:85-86`): 163 840 bytes only for `/status` in a session
    /// that negotiated phone control, 98 304 for every other path and every unnegotiated session. The same bound
    /// applies on LAN and inside the rendezvous tunnel (`A/RemoteHttp.kt:63-65`, `A/StreamReceiver.kt:1868`).
    public static func bodyLimit(path: String, negotiated: Bool) -> Int {
        negotiated && path == Path.status ? phoneControlBodyBytes : maxBodyBytes
    }

    // MARK: Constants

    /// Fixed endpoint paths.
    public enum Path {
        public static let pair = "/pair"
        public static let offer = "/offer"
        public static let cancelOffer = "/cancel-offer"
        public static let answer = "/answer"
        public static let status = "/status"
        public static let microphone = "/microphone"
        public static let recoverOffer = "/recover-offer"
        public static let recoverAnswer = "/recover-answer"
        public static let stop = "/stop"
    }

    /// Header names and values, verbatim.
    public enum Header {
        public static let offerAttempt = "X-MicDrop-Offer-Attempt"
        public static let trickleICE = "X-MicDrop-Trickle-ICE"
        public static let continuousICE = "X-MicDrop-Continuous-ICE"
        /// `PhoneControl.header` (`A/PhoneControl.kt:81`).
        public static let phoneControl = PhoneControl.header
        /// `SessionResume.header` (`A/SessionResume.kt:6`).
        public static let sessionResume = SessionResume.header
        /// `SessionResume.reasonHeader` (`A/SessionResume.kt:7`).
        public static let sessionResumeReason = SessionResume.reasonHeader
        public static let enabledValue = "1"
    }

    /// Client timeouts.
    public enum Timeouts {
        public static let defaultMs = 8_000
        public static let offerMs = 40_000
        public static let answerMs = 8_000
        public static let statusMs = 2_000
        public static let microphoneMs = 8_000
        /// `/microphone` during headset restoration: `clamp(remaining, 1, 2000)`.
        public static let microphoneRestoreMaxMs = 2_000
        public static let cancelOfferMs = 5_000
        public static let recoverOfferMaxMs = 18_000
        public static let recoverAnswerMaxMs = 5_000
        /// Remote minimum for every path except `/stop`, `/recover-*` and stopping requests.
        public static let remoteMinimumMs = 8_000
        /// LAN TCP connect bound: `min(timeout, 8000)`.
        public static let lanConnectMaxMs = 8_000

        /// `/stop` (cleanup and previous-Stop retry): 5000 remote / 2000 LAN (`:829`).
        public static func stopMs(remote: Bool) -> Int { remote ? 5_000 : 2_000 }

        /// LAN connect timeout `min(timeout, 8000)` (`A/StreamReceiver.kt:1675`).
        public static func lanConnectMs(_ timeoutMs: Int) -> Int { min(timeoutMs, lanConnectMaxMs) }
    }

    // MARK: Pure validation (used by the transports' precondition checks)

    /// `^/[a-z-]+$`.
    public static func pathIsValid(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        guard bytes.count >= 2, bytes[0] == 0x2F else { return false }
        return bytes.dropFirst().allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D }
    }

    /// `^[A-Za-z0-9_-]{43}$` (session bearer, v1/v2 token, offer nonce; `A/RemoteHttp.kt:41-43`).
    public static func credentialIsValid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 43 else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x5F || byte == 0x2D
        }
    }

    /// Effective request timeout (`A/StreamReceiver.kt:1655-1659`).
    ///
    /// LAN: `timeoutMs` (the LAN transport applies connect `min(t, 8000)` and per-read idle `t`, and
    /// ends the whole request at `min(t, connect cap) + t`).
    /// Remote: `requested = (stopping || path == "/stop" || path.hasPrefix("/recover-")) ? t : max(t, 8000)`,
    /// then capped by `max(recoveryRemainingMs, 1)` when `!stopping` and LAN recovery is active
    /// (pass `recoveryRemainingMs` only while `LanRecovery.active`).
    public static func effectiveTimeoutMs(
        path: String, timeoutMs: Int, stopping: Bool, remote: Bool,
        recoveryRemainingMs: Int64?
    ) -> Int {
        guard remote else { return timeoutMs }
        let exempt = stopping || path == Path.stop || path.hasPrefix("/recover-")
        let requested = exempt ? timeoutMs : max(timeoutMs, Timeouts.remoteMinimumMs)
        guard !stopping, let remaining = recoveryRemainingMs else { return requested }
        let bounded = Int(clamping: max(remaining, 1))
        return min(requested, bounded)
    }

    // MARK: Request builders (exact bodies)

    /// `Authorization: Bearer <token>` iff the token is non-empty (`A/StreamReceiver.kt:1677`,
    /// `A/RemoteHttp.kt:50`): a v3 link token is `""`, so v3 `/offer` and `/cancel-offer` carry none.
    public static func bearerToken(for token: String) -> String? {
        token.isEmpty ? nil : token
    }

    // There is no `/offer` request builder: the session worker's `transportRequest` builds every `/offer`, because
    // it alone knows the negotiation headers (`X-MicDrop-Phone-Control`, `X-MicDrop-Session-Resume`, the v3
    // connection windows) a v3 offer must carry.

    /// `{"version":V[,"microphone_return_version":1[,"duplex_version":1]]}` (`StreamMode.offerFields(version:)`,
    /// `A/StreamMode.kt:31-37`).
    public static func offerBody(mode: StreamMode, version: Int) throws -> Data {
        let fields = try mode.offerFields(version: version)
        return ControlJSON(members: fields.map { ControlJSON.Member($0.key, .int($0.value)) }).encoded()
    }

    /// `POST /cancel-offer` `{"version":V}` with the same nonce. Sent with `stopping = true`, timeout
    /// `Timeouts.cancelOfferMs`.
    public static func cancelOffer(version: Int, token: String, attempt: String?) -> ControlRequest {
        ControlRequest(
            path: Path.cancelOffer, bearer: bearerToken(for: token), offerAttempt: attempt,
            body: versionBody(version))
    }

    /// `{"version":V}`.
    public static func versionBody(_ version: Int) -> Data {
        let body: ControlJSON = ["version": .int(version)]
        return body.encoded()
    }

    /// `POST /answer` `{"version":V,"sdp":"<answer>"}` with the session bearer.
    public static func answer(version: Int, sdp: String, session: String) -> ControlRequest {
        let body: ControlJSON = ["version": .int(version), "sdp": .string(sdp)]
        return ControlRequest(path: Path.answer, bearer: bearerToken(for: session), body: body.encoded())
    }

    /// `/status`: `GET` when `body == nil`, else `POST` of the envelope built by `StatusBody`
    /// (`{"version":V,"android":…,"ice":…,"continuous_ice":…}`). A session that negotiated phone control sends and
    /// receives up to `phoneControlBodyBytes`.
    public static func status(
        session: String, body: Data?, phoneControlNegotiated: Bool = false
    ) -> ControlRequest {
        ControlRequest(
            path: Path.status, bearer: bearerToken(for: session), body: body,
            phoneControlNegotiated: phoneControlNegotiated)
    }

    /// `POST /stop` `{"reason":"<wire>"}` or `{"reason":"<wire>","diagnostics":<terminal>}`. `diagnostics` is the
    /// already-encoded terminal evidence object (`TerminalEvidence.json(...)`), spliced verbatim.
    public static func stop(session: String, reason: String, diagnostics: Data? = nil) -> ControlRequest {
        ControlRequest(
            path: Path.stop, bearer: bearerToken(for: session), body: stopBody(reason: reason, diagnostics: diagnostics)
        )
    }

    public static func stopBody(reason: String, diagnostics: Data?) -> Data {
        var bytes: [UInt8] = Array("{\"reason\":".utf8)
        ControlJSON.Value.encodeString(reason, into: &bytes)
        if let diagnostics {
            bytes.append(contentsOf: Array(",\"diagnostics\":".utf8))
            bytes.append(contentsOf: [UInt8](diagnostics))
        }
        bytes.append(0x7D)
        return Data(bytes)
    }

    /// `POST /microphone` `{"version":3,"muted":<bool>}`.
    public static func microphone(session: String, muted: Bool) -> ControlRequest {
        let body: ControlJSON = ["version": .int(3), "muted": .bool(muted)]
        return ControlRequest(path: Path.microphone, bearer: bearerToken(for: session), body: body.encoded())
    }

    /// `POST /recover-offer` `{"version":3,"generation":G}`.
    public static func recoverOffer(session: String, generation: Int64) -> ControlRequest {
        let body: ControlJSON = ["version": .int(3), "generation": .int64(generation)]
        return ControlRequest(path: Path.recoverOffer, bearer: bearerToken(for: session), body: body.encoded())
    }

    /// `POST /recover-answer` `{"version":3,"generation":G,"sdp":"<answer>"}`.
    public static func recoverAnswer(session: String, generation: Int64, sdp: String) -> ControlRequest {
        let body: ControlJSON = ["version": .int(3), "generation": .int64(generation), "sdp": .string(sdp)]
        return ControlRequest(path: Path.recoverAnswer, bearer: bearerToken(for: session), body: body.encoded())
    }
}
