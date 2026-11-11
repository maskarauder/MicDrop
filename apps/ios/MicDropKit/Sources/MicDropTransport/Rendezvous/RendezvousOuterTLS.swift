#if canImport(NIOTransportServices)
    import Dispatch
    import Foundation
    import MicDropCore
    import Network
    import Security

    /// Outer rendezvous TLS on Network.framework: Apple's platform trust, `SecTrust` with the SSL server policy for the
    /// route's host against the iOS trust store, accepted on 2026-10-27. Like Android's default `SSLSocketFactory` it
    /// ships no CA list, but the iOS store also holds roots the user enabled for full trust or that device management
    /// installed, which Android's default trust excludes. NIOSSL is reserved for the inner pinned TLS, so such a root
    /// never decides the paired host's identity.
    public enum RendezvousOuterTLS {
        /// `NWProtocolTLS.Options` with min = max = TLS 1.3 (Android `protocols = ["TLSv1.3"]`), SNI =
        /// `route.connectHost` only for DNS names (no SNI for IP literals), no ALPN (Android sends none;
        /// Go offers only `http/1.1`), and a verify block that sets `SecPolicyCreateSSL(true, host)`,
        /// for `.anchors` sets `SecTrustSetAnchorCertificates` + `SecTrustSetAnchorCertificatesOnly(true)`
        /// (tests only), evaluates with `SecTrustEvaluateWithError`, and on failure records
        /// `OuterTrustClassifier.problem(error:trust:)` in `verdict` before completing `false`.
        ///
        /// - Parameter queue: the verify block's queue (not the NIO loop).
        public static func makeOptions(
            route: RemoteRoute, verdict: OuterTrustVerdictBox, policy: OuterTrustPolicy,
            queue: DispatchQueue
        ) -> NWProtocolTLS.Options {
            let tls = NWProtocolTLS.Options()
            let options = tls.securityProtocolOptions
            sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
            sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
            if !route.hostIsIPLiteral { sec_protocol_options_set_tls_server_name(options, route.connectHost) }
            sec_protocol_options_set_verify_block(
                options,
                { _, secTrust, complete in
                    let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                    guard
                        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, route.connectHost as CFString))
                            == errSecSuccess
                    else {
                        verdict.record(.identity)
                        complete(false)
                        return
                    }
                    if case .anchors(let roots) = policy {
                        let certificates = roots.compactMap { SecCertificateCreateWithData(nil, Data($0) as CFData) }
                        guard certificates.count == roots.count, !certificates.isEmpty,
                            SecTrustSetAnchorCertificates(trust, certificates as CFArray) == errSecSuccess,
                            SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
                        else {
                            verdict.record(.identity)
                            complete(false)
                            return
                        }
                    }
                    var error: CFError?
                    if SecTrustEvaluateWithError(trust, &error) {
                        complete(true)
                    } else {
                        verdict.record(OuterTrustClassifier.problem(error: error, trust: trust))
                        complete(false)
                    }
                }, queue)
            return tls
        }
    }

    /// Maps a failed `SecTrustEvaluateWithError` to the outer problem: `errSecCertificateExpired` (−67818) /
    /// `errSecCertificateNotValidYet` (−67819), or a failed temporal check in `SecTrustCopyResult` details
    /// (`TemporalValidity`, `ValidLeaf`, `ValidIntermediates`, `ValidRoot` = false) → `.certificateTime`; anything else
    /// (untrusted root, host-name mismatch, revoked, CT failure…) → `.identity`. Validate the codes on device.
    public enum OuterTrustClassifier {
        public static let certificateExpired: Int = -67818
        public static let certificateNotValidYet: Int = -67819

        public static func problem(error: CFError?, trust: SecTrust) -> SignalingTLSFailure.Problem {
            if let error, [certificateExpired, certificateNotValidYet].contains(CFErrorGetCode(error)) {
                return .certificateTime
            }
            func temporalFailure(_ value: Any) -> Bool {
                if let dictionary = value as? [String: Any] {
                    for (key, child) in dictionary {
                        if ["TemporalValidity", "ValidLeaf", "ValidIntermediates", "ValidRoot"].contains(key),
                            let valid = child as? Bool, !valid
                        {
                            return true
                        }
                        if temporalFailure(child) { return true }
                    }
                } else if let array = value as? [Any] {
                    return array.contains(where: temporalFailure)
                }
                return false
            }
            if let result = SecTrustCopyResult(trust), temporalFailure(result) { return .certificateTime }
            return .identity
        }
    }
#endif
