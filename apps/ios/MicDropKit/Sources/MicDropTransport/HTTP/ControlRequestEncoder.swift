import Foundation
import MicDropCore
import NIOCore

/// The single control-plane request codec for LAN and remote: exactly the `RemoteHttp.kt:40-56` HTTP/1.0 bytes. No
/// `User-Agent`, no `Accept-Encoding`, no `Origin`, no query, no `Transfer-Encoding`, no `Expect`.
///
/// ```
/// <GET|POST> <path> HTTP/1.0\r\n GET iff body == nil Host: <lan-ip>:<port>\r\n the paired record's LAN endpoint (also
/// through the tunnel) Connection: close\r\n Authorization: Bearer <token>\r\n only if bearer is non-empty
/// X-MicDrop-Offer-Attempt: <nonce>\r\n only if offerAttempt != nil X-MicDrop-Phone-Control: 1\r\n only if
/// phoneControlOffer (v3 /offer) X-MicDrop-Session-Resume: 1\r\n only if sessionResume (v3 /offer of a Play/resume)
/// X-MicDrop-Trickle-ICE: 1\r\n only if trickleHeaders X-MicDrop-Continuous-ICE: 1\r\n only if trickleHeaders (always
/// together) X-MicDrop-Recovery-Window-Ms: <ms>\r\n only if connectionPreferences != nil (offer)
/// X-MicDrop-Setup-Window-Ms: <ms>\r\n only if connectionPreferences != nil Content-Type: application/json\r\n only if
/// body != nil Content-Length: <decimal byte count>\r\n only if body != nil \r\n <body>
/// ```
///
/// The phone-control and resume lines follow the offer nonce in Android's order (`RemoteHttp.kt:70-76`); Go ignores
/// header order. Each appears at most once, because the host answers a repeated header with 400.
public enum ControlRequestEncoder {
    /// `MAX_BODY = 96 * 1024` for request bodies (`RemoteHttp.kt:46,65`; host `server.go:22`). A negotiated
    /// phone-control `/status` allows `ControlRequest.phoneControlBodyBytes` (`ControlRequest.bodyBudget`).
    public static let maxBodyBytes = ControlRequest.maxBodyBytes
    /// Header names verbatim (`OfferAttempt.kt:19`, `TrickleIce.kt:75`, `ContinuousIce.kt:61`, `PhoneControl.kt:81`,
    /// `SessionResume.kt:6`).
    public static let offerAttemptHeader = ControlRequest.Header.offerAttempt
    public static let trickleHeader = ControlRequest.Header.trickleICE
    public static let continuousHeader = ControlRequest.Header.continuousICE
    public static let phoneControlHeader = ControlRequest.Header.phoneControl
    public static let sessionResumeHeader = ControlRequest.Header.sessionResume
    public static let sessionResumeReasonHeader = ControlRequest.Header.sessionResumeReason

    /// A precondition violation (Android `IllegalArgumentException`, `RemoteHttp.kt:40-46`): a programming error,
    /// raised before any connection is opened; never retryable (`SETUP_FAILED`).
    public struct InvalidRequest: Error, Sendable, Equatable {
        public enum Reason: String, Sendable, Equatable {
            /// `path` does not match `^/[a-z-]+$`.
            case path
            /// `bearer` is neither empty/nil nor `^[A-Za-z0-9_-]{43}$`.
            case bearer
            /// nonce on a path other than `/offer`/`/cancel-offer`, or not `^[A-Za-z0-9_-]{43}$`.
            case offerAttempt
            /// trickle headers on a path other than `/offer`.
            case trickle
            /// Connection deadline negotiation outside `/offer`.
            case connectionPreferences
            /// body larger than `bodyBudget` (98 304 bytes; 163 840 for a negotiated phone-control `/status`).
            case bodyTooLarge
            /// `maxResponseBytes` outside `1...bodyBudget`.
            case responseCap
            /// `X-MicDrop-Phone-Control` outside `/offer`.
            case phoneControl
            /// `X-MicDrop-Session-Resume` outside `/offer`.
            case sessionResume
        }

        public let reason: Reason

        public init(_ reason: Reason) {
            self.reason = reason
        }
    }

    /// preconditions, checked before any I/O.
    public static func validate(_ request: ControlRequest) throws {
        guard ControlRequest.pathIsValid(request.path) else {
            throw InvalidRequest(.path)
        }
        if let bearer = request.bearer, !bearer.isEmpty, !ControlRequest.credentialIsValid(bearer) {
            throw InvalidRequest(.bearer)
        }
        if let nonce = request.offerAttempt {
            guard request.path == "/offer" || request.path == "/cancel-offer",
                ControlRequest.credentialIsValid(nonce)
            else {
                throw InvalidRequest(.offerAttempt)
            }
        }
        if request.trickleHeaders, request.path != "/offer" {
            throw InvalidRequest(.trickle)
        }
        if request.connectionPreferences != nil, request.path != "/offer" {
            throw InvalidRequest(.connectionPreferences)
        }
        if request.phoneControlOffer, request.path != "/offer" {
            throw InvalidRequest(.phoneControl)
        }
        if request.sessionResume || request.sessionResumeReason != nil, request.path != "/offer" {
            throw InvalidRequest(.sessionResume)
        }
        if request.sessionResumeReason != nil, !request.sessionResume {
            throw InvalidRequest(.sessionResume)
        }
        // Above 98 304 bytes only for a negotiated `/status` (`PhoneControl.kt:85-86`, `RemoteHttp.kt:63-65`).
        let budget = request.bodyBudget
        if let body = request.body, body.count > budget {
            throw InvalidRequest(.bodyTooLarge)
        }
        guard (1...budget).contains(request.maxResponseBytes) else {
            throw InvalidRequest(.responseCap)
        }
    }

    /// The exact request bytes (header block US-ASCII with CRLF, then the raw body).
    /// - Parameter host: the paired record's LAN endpoint (`Host: 10.0.0.1:9844`), used on LAN and
    ///   inside the remote tunnel alike (`RemoteHttp.kt:48`).
    public static func encode(_ request: ControlRequest, host: LANEndpoint) throws -> [UInt8] {
        try validate(request)
        var head = request.body == nil ? "GET " : "POST "
        head += request.path
        head += " HTTP/1.0\r\n"
        head += "Host: \(host.host.description):\(host.port)\r\n"
        head += "Connection: close\r\n"
        if let bearer = request.bearer, !bearer.isEmpty {
            head += "Authorization: Bearer \(bearer)\r\n"
        }
        if let nonce = request.offerAttempt {
            head += "\(offerAttemptHeader): \(nonce)\r\n"
        }
        if request.phoneControlOffer {
            head += "\(phoneControlHeader): 1\r\n"
        }
        if request.sessionResume {
            head += "\(sessionResumeHeader): 1\r\n"
        }
        if let reason = request.sessionResumeReason {
            head += "\(sessionResumeReasonHeader): \(reason.wire)\r\n"
        }
        if request.trickleHeaders {
            head += "\(trickleHeader): 1\r\n"
            head += "\(continuousHeader): 1\r\n"
        }
        if let preferences = request.connectionPreferences {
            head += "\(ConnectionPreferences.recoveryHeader): \(preferences[.recovery])\r\n"
            head += "\(ConnectionPreferences.setupHeader): \(preferences[.setup])\r\n"
        }
        if let body = request.body {
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        var bytes = Array(head.utf8)
        if let body = request.body {
            bytes.append(contentsOf: body)
        }
        return bytes
    }

    /// `encode` into a `ByteBuffer` from `allocator`.
    public static func encode(
        _ request: ControlRequest, host: LANEndpoint,
        allocator: ByteBufferAllocator
    ) throws -> ByteBuffer {
        let bytes = try encode(request, host: host)
        var buffer = allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return buffer
    }
}
