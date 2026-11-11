import Foundation
import MicDropCore
import Security
import WebRTC

/// WebRTC's TURN/TLS certificate-verifier callback backed by iOS platform trust (Kotlin `TurnTlsTrust.verify`,
/// `TurnTlsTrust.kt:24-67`; wiring `StreamReceiver.kt:499-504`).
///
/// libwebrtc validates TURN/TLS with BoringSSL and its bundled root list, which omits Let's Encrypt's ISRG roots,
/// and consults no iOS trust unless the peer is created with this callback. The pinned SDK then passes the
/// server's chain (leaf first) to `verifyChain:`; with only `verify:` it would pass the leaf alone, which cannot
/// validate. WebRTC still checks the TURN URL's hostname after this callback (`SSLPostConnectionCheck`), so the
/// policy names no host: the callback carries none, and one verifier serves every TURN URL of the peer and every
/// restart's servers. Peer-supplied certificates are chain-building hints only, never anchors. There is no
/// `RTCTlsCertPolicyInsecureNoCheck` and no bypass setting.
///
/// Trust is Apple's standard platform evaluation, accepted on 2026-10-27 (handoff "TURN/TLS trust"):
/// `SecTrust` against the iOS trust store, with no anchors and no fixed date in production, and no MicDrop CA list.
/// That store holds the system roots and also any root the user enabled for full trust (Settings > General > About >
/// Certificate Trust Settings) or that device management installed. Android's default trust manager trusts the
/// system CAs only, without user-added ones (`TurnTlsTrust.kt:27-31`), so a relay chain under such a root can be
/// trusted here but rejected on Android. Only the relay hop depends on it: the paired host's identity
/// (`HostTrustVerifier`) and the DTLS fingerprint check never consult this store.
///
/// Called on WebRTC's network thread. Evaluation is synchronous and never fetches intermediates or revocation
/// data (Android's default trust manager fetches neither), so a handshake in progress keeps Stop latency bounded
/// (peer close waits on that thread); a chain without its intermediate is rejected. The evaluation error,
/// certificate subjects, DER and URLs are never logged or stored: only the bounded counters leave this type.
final class TurnTLSTrustVerifier: NSObject, RTCSSLCertificateVerifier, @unchecked Sendable {
    /// Evaluation inputs. Production uses the defaults: no anchors, so the iOS trust store decides (user- and
    /// MDM-trusted roots included), and the current time.
    struct Evaluator {
        /// Tests only: in-memory anchors (then `SecTrustSetAnchorCertificatesOnly(true)`).
        var anchors: [SecCertificate]?
        /// Tests only: a fixed evaluation time.
        var verifyDate: Date?
        /// `SecTrustCreateWithCertificates`; replaceable to test the provider-failure path.
        var createTrust: ([SecCertificate], SecPolicy) -> SecTrust? = Evaluator.systemTrust

        static func systemTrust(_ certificates: [SecCertificate], _ policy: SecPolicy) -> SecTrust? {
            var trust: SecTrust?
            guard SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust) == errSecSuccess else {
                return nil
            }
            return trust
        }
    }

    let counters: TurnTLSTrustCounters
    /// Read-only, so the tests can pin production's platform trust (no anchors, no verify date).
    let evaluator: Evaluator

    init(counters: TurnTLSTrustCounters, evaluator: Evaluator = Evaluator()) {
        self.counters = counters
        self.evaluator = evaluator
        super.init()
    }

    /// Leaf-only callback: checked as a one-certificate chain (`StreamReceiver.kt:501`).
    @objc(verify:)
    func verify(_ derCertificate: Data) -> Bool {
        verifyChain([derCertificate])
    }

    /// Full-chain callback, leaf first (`StreamReceiver.kt:502`). The explicit selector pins the name the SDK's
    /// adapter looks up.
    @objc(verifyChain:)
    func verifyChain(_ derCertificateChain: [Data]) -> Bool {
        let result = autoreleasepool { evaluate(derCertificateChain) }
        return counters.record(result)
    }

    /// `TurnTlsTrust.verify` steps in order: bounds and framing, certificate parsing, platform trust.
    private func evaluate(_ chain: [Data]) -> TurnTLSTrustResult {
        guard TurnTLSTrustInput.isAcceptable(chain) else { return .invalidCertificate }
        var certificates: [SecCertificate] = []
        certificates.reserveCapacity(chain.count)
        for der in chain {
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                return .invalidCertificate
            }
            certificates.append(certificate)
        }
        // Server authentication without a name, like Android's `checkServerTrusted`; WebRTC checks the name.
        let policy = SecPolicyCreateSSL(true, nil)
        guard let trust = evaluator.createTrust(certificates, policy),
            SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess
        else { return .unavailable }
        if let anchors = evaluator.anchors {
            guard SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
                SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
            else { return .unavailable }
        }
        if let verifyDate = evaluator.verifyDate {
            guard SecTrustSetVerifyDate(trust, verifyDate as CFDate) == errSecSuccess else { return .unavailable }
        }
        if SecTrustEvaluateWithError(trust, nil) { return .trusted }
        var result = SecTrustResultType.invalid
        guard SecTrustGetTrustResult(trust, &result) == errSecSuccess else { return .unavailable }
        switch result {
        case .invalid, .otherError:
            return .unavailable
        default:
            // `.deny`, `.recoverableTrustFailure`, `.fatalTrustFailure` and any other value after a failed
            // evaluation.
            return .rejected
        }
    }
}
