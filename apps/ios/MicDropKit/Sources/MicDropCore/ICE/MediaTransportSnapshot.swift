import Foundation

/// Selected-pair transport labels for the report's `media_transport` object and the copy report (Kotlin
/// `MediaTransportSnapshot`, `MediaTransport.kt`; host validation Go `internal/rtc/media_transport.go:14-41`).
///
/// A relay candidate's `protocol` can be UDP even when this endpoint reaches TURN over TCP or TLS;
/// only the local candidate knows that hop (`relay_protocol`). Never infer the other endpoint's hop.
public struct MediaTransportSnapshot: Equatable, Sendable {
    public static let candidateTypes: Set<String> = ["host", "srflx", "prflx", "relay"]
    public static let directTypes: Set<String> = ["host", "srflx", "prflx"]
    public static let candidateProtocols: Set<String> = ["udp", "tcp"]
    public static let turnProtocols: Set<String> = ["udp", "tcp", "tls"]

    /// All four labels `unavailable` (missing/older host or malformed report).
    public static let unavailable = MediaTransportSnapshot()

    public var localType: String
    public var remoteType: String
    public var candidateProtocol: String
    public var relayProtocol: String

    public init(
        localType: String = "unavailable", remoteType: String = "unavailable",
        candidateProtocol: String = "unavailable", relayProtocol: String = "unavailable"
    ) {
        self.localType = localType
        self.remoteType = remoteType
        self.candidateProtocol = candidateProtocol
        self.relayProtocol = relayProtocol
    }

    /// `relay` / `direct` / `unavailable` (`MediaTransport.kt:10-14`).
    public var path: String {
        if localType == "relay" || remoteType == "relay" || Self.turnProtocols.contains(relayProtocol) {
            return "relay"
        }
        if Self.directTypes.contains(localType) && Self.directTypes.contains(remoteType) {
            return "direct"
        }
        return "unavailable"
    }

    /// The report's legacy `path` text, e.g. `relay / udp` (`MediaTransport.kt:15`).
    public var legacyPath: String {
        path + (Self.candidateProtocols.contains(candidateProtocol) ? " / \(candidateProtocol)" : "")
    }

    /// `media_transport` wire object, Kotlin key order (`MediaTransport.kt:17-19`).
    public func json() -> DiagnosticJSON {
        let fields: [(key: String, value: DiagnosticJSON)] = [
            ("version", .int(1)),
            ("local_candidate_type", .string(localType)),
            ("remote_candidate_type", .string(remoteType)),
            ("candidate_protocol", .string(candidateProtocol)),
            ("relay_protocol", .string(relayProtocol)),
        ]
        return .object(fields)
    }

    /// Copy-report label of the local TURN hop (`MediaTransport.kt:21-25`).
    public func turnText() -> String {
        switch relayProtocol {
        case "udp": return "UDP"
        case "tcp": return "TCP"
        case "tls": return "TLS"
        case "not_applicable": return "not used"
        default: return "unavailable"
        }
    }

    /// Copy-report lines comparing both TURN hops (`StreamReceiver.kt:759-760`).
    public static func selectedTURNText(phone: MediaTransportSnapshot, windows: MediaTransportSnapshot) -> String {
        "Selected TURN connections — phone: \(phone.turnText()) · Windows: \(windows.turnText())"
            + "\nTURN connection protocols are separate from the ICE candidate protocol shown in Media path."
    }

    /// Labels from the selected pair's `local-candidate` / `remote-candidate` stats
    /// (`MediaTransport.kt:33-48`). The stats owner finds the pair; this only labels it.
    public static func selected(local: RtcSample?, remote: RtcSample?) -> MediaTransportSnapshot {
        func string(_ sample: RtcSample?, _ key: String) -> String? {
            if case .string(let value)? = sample?.members[key] { return value }
            return nil
        }
        func label(_ value: String?, _ allowed: Set<String>) -> String {
            guard let value = value, allowed.contains(value) else { return "unavailable" }
            return value
        }
        let localType = label(string(local, "candidateType"), candidateTypes)
        let remoteType = label(string(remote, "candidateType"), candidateTypes)
        let relayPresent = local?.members["relayProtocol"] != nil
        let relay = string(local, "relayProtocol")
        let hop: String
        switch localType {
        case "relay":
            hop = label(relay, turnProtocols)
        case "prflx":
            // libwebrtc can retain relayProtocol on a peer-reflexive candidate derived from TURN;
            // missing is normal for direct ICE (`MediaTransport.kt:40-42`).
            hop = (!relayPresent || relay == "") ? "not_applicable" : label(relay, turnProtocols)
        case "host", "srflx":
            hop = "not_applicable"
        default:
            hop = "unavailable"
        }
        return MediaTransportSnapshot(
            localType: localType, remoteType: remoteType,
            candidateProtocol: label(string(local, "protocol"), candidateProtocols),
            relayProtocol: hop)
    }

    /// Windows' own observation from the host `/status` `media_transport` object
    /// (`MediaTransport.kt:52-68`). Pass each field only if it has the right JSON type (`version`
    /// only when it is a JSON integer, never a boolean); any rejection → `unavailable`.
    public static func reported(
        version: Int?, localType: String?, remoteType: String?,
        candidateProtocol: String?, relayProtocol: String?
    ) -> MediaTransportSnapshot {
        guard version == 1, let local = localType, let remote = remoteType,
            let proto = candidateProtocol, let relay = relayProtocol
        else { return .unavailable }
        guard local == "unavailable" || candidateTypes.contains(local),
            remote == "unavailable" || candidateTypes.contains(remote),
            proto == "unavailable" || candidateProtocols.contains(proto),
            relay == "unavailable" || relay == "not_applicable" || turnProtocols.contains(relay)
        else { return .unavailable }
        let rejected: Bool
        switch local {
        case "host", "srflx": rejected = relay != "not_applicable"
        case "relay": rejected = relay == "not_applicable"
        case "unavailable": rejected = relay != "unavailable"
        default: rejected = false
        }
        if rejected { return .unavailable }
        return MediaTransportSnapshot(
            localType: local, remoteType: remote, candidateProtocol: proto, relayProtocol: relay)
    }

    /// `reported(...)` read from a raw `/status` response body; an absent `media_transport`
    /// member or any type mismatch yields `unavailable` (`StreamReceiver.kt:754-757`).
    public static func reported(statusBody: [UInt8]) -> MediaTransportSnapshot {
        guard let envelope = try? JSONDecoder().decode(MediaTransportStatusEnvelope.self, from: Data(statusBody)),
            let fields = envelope.mediaTransport
        else { return .unavailable }
        return reported(
            version: fields.version, localType: fields.localCandidateType,
            remoteType: fields.remoteCandidateType, candidateProtocol: fields.candidateProtocol,
            relayProtocol: fields.relayProtocol)
    }
}

/// Decoding shell for the host's `media_transport` member; other `/status` keys are ignored.
private struct MediaTransportStatusEnvelope: Decodable {
    struct Fields: Decodable {
        let version: Int?
        let localCandidateType: String?
        let remoteCandidateType: String?
        let candidateProtocol: String?
        let relayProtocol: String?

        private enum CodingKeys: String, CodingKey {
            case version
            case localCandidateType = "local_candidate_type"
            case remoteCandidateType = "remote_candidate_type"
            case candidateProtocol = "candidate_protocol"
            case relayProtocol = "relay_protocol"
        }
    }

    let mediaTransport: Fields?

    private enum CodingKeys: String, CodingKey {
        case mediaTransport = "media_transport"
    }
}
