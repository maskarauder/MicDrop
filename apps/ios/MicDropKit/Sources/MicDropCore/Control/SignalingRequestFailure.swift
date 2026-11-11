import Foundation

/// Fixed-label transport stage of one signaling request (`SignalingFailure.kt:47-51`). Raw values are the report
/// labels, verbatim.
public enum SignalingRequestPhase: String, Sendable, Equatable, CaseIterable {
    /// LAN: connect, inner TLS and request write.
    case lanRequest = "lan_request"
    /// Rendezvous: TCP, outer TLS and the WebSocket upgrade.
    case rendezvousConnect = "rendezvous_connect"
    /// Rendezvous: upgraded, waiting for the Windows `ready` frame.
    case waitingForWindows = "waiting_for_windows"
    /// Rendezvous: inner paired TLS after `ready`.
    case windowsTLS = "windows_tls"
    /// Rendezvous: writing the HTTP request.
    case requestWrite = "request_write"
    /// Request written; waiting for the status line and headers.
    case responseHeaders = "response_headers"
    /// A 200 header block was accepted; reading the body.
    case responseBody = "response_body"
}

/// Current stage of one in-flight request, advanced by its transport from any thread and read by the
/// session worker after a failure (Kotlin `RemoteHttp.phase` / `localRequest` `phase`). The stage only
/// moves forward in declaration order, so a late or reordered transport callback cannot regress it.
public final class SignalingRequestProgress: @unchecked Sendable {
    private let stage: Locked<SignalingRequestPhase>

    public init(_ initial: SignalingRequestPhase) {
        stage = Locked(initial)
    }

    public var phase: SignalingRequestPhase { stage.value }

    public func advance(to phase: SignalingRequestPhase) {
        let order = SignalingRequestPhase.allCases
        stage.withLock { current in
            if let next = order.firstIndex(of: phase), let now = order.firstIndex(of: current), next > now {
                current = phase
            }
        }
    }
}

/// `signalingRequestFailureText` (`SignalingFailure.kt:72-88`): only fixed labels, never an error
/// message, address, credential or arbitrary request path.
/// `route=<lan|rendezvous> · request=<operation> · phase=<phase> · category=<category> · elapsed=<ms> ms`.
public func signalingRequestFailureText(
    direct: Bool, path: String, phase: SignalingRequestPhase, elapsedMs: Int64, error: Error
) -> String {
    let operations = [
        "/offer", "/answer", "/status", "/recover-offer", "/recover-answer", "/microphone", "/stop", "/cancel-offer",
    ]
    let operation = operations.contains(path) ? String(path.dropFirst()) : "other"
    let chain = ConnectionFailure.causes(of: error)
    let category: String
    if let http = chain.lazy.compactMap({ $0 as? HTTPFailure }).first {
        category = "http_\(http.status)"
    } else if let tls = chain.lazy.compactMap({ $0 as? SignalingTLSFailure }).first {
        category = "tls_\(tls.layer.rawValue)_\(tls.problem.rawValue)"
    } else if chain.contains(where: { $0 is SignalingNetworkChanged }) {
        category = "network_changed"
    } else if ConnectionFailure.isTimeout(error) {
        category = "timeout"
    } else if chain.contains(where: { $0 is SignalingStreamEnded }) {
        category = "transport_eof"
    } else if ConnectionFailure.isCancellation(error) {
        category = "cancelled"
    } else {
        // iOS transports do not distinguish DNS, refused and no-route failures.
        category = "network_io"
    }
    return "route=\(direct ? "lan" : "rendezvous") · request=\(operation) · phase=\(phase.rawValue) · "
        + "category=\(category) · elapsed=\(max(0, elapsedMs)) ms"
}

/// Worker-owned, fixed four-entry history of failed ordinary signaling requests (`StreamReceiver.kt:123,1890-1893`).
/// Stopping requests are never recorded, so cleanup cannot overwrite the failure that ended the session.
public struct SignalingRequestFailures: Sendable, Equatable {
    public static let capacity = 4
    public private(set) var entries: [String] = []

    public init() {}

    /// Appends `"<uptime> ms · <detail>"`, dropping the oldest entry beyond `capacity`.
    public mutating func record(uptimeMs: Int64, _ detail: String) {
        if entries.count == Self.capacity { entries.removeFirst() }
        entries.append("\(uptimeMs) ms · \(detail)")
    }

    /// Copy-report block (`StreamReceiver.kt:851-852`); nil when nothing failed.
    public var text: String? {
        entries.isEmpty ? nil : "Recent signaling request failures (phone uptime):\n" + entries.joined(separator: "\n")
    }
}
