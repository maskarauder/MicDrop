import Foundation
import MicDropCore
import Security
import XCTest

@testable import MicDrop

/// iOS platform trust behind WebRTC's TURN/TLS verifier callback, a port of `TurnTlsTrustPlatformTest.kt`.
/// Test roots are in-memory anchors only (never added to a keychain or trust store); no peer or native media
/// engine is created. Every evaluation runs on a background queue, like WebRTC's network thread, because
/// synchronous SecTrust evaluation must not run on the main thread.
final class TurnTLSTrustVerifierTests: XCTestCase {
    private typealias Fixtures = TurnTLSTestCertificates

    private func verifier(
        root: String? = Fixtures.root, verifyDate: Date? = Fixtures.verifyDate,
        createTrust: (([SecCertificate], SecPolicy) -> SecTrust?)? = nil
    ) throws -> TurnTLSTrustVerifier {
        var evaluator = TurnTLSTrustVerifier.Evaluator()
        evaluator.anchors = try root.map { [try Fixtures.certificate($0)] }
        evaluator.verifyDate = verifyDate
        if let createTrust { evaluator.createTrust = createTrust }
        return TurnTLSTrustVerifier(counters: TurnTLSTrustCounters(), evaluator: evaluator)
    }

    /// Runs `body` on a background queue and waits for its result.
    private func offMain(_ body: @escaping @Sendable () -> Bool) -> Bool {
        let result = Locked<Bool?>(nil)
        let done = expectation(description: "evaluated")
        DispatchQueue.global(qos: .userInitiated).async {
            result.value = body()
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        return result.value ?? false
    }

    private func verify(_ verifier: TurnTLSTrustVerifier, _ chain: [Data]) -> Bool {
        offMain { verifier.verifyChain(chain) }
    }

    func testAcceptsFullRSAAndECChainsUsingPlatformTrust() throws {
        let rsa = try verifier()
        XCTAssertTrue(verify(rsa, try Fixtures.chain(Fixtures.server, Fixtures.intermediate)))
        XCTAssertEqual(rsa.counters.snapshot(), TurnTLSTrustSnapshot(checks: 1, failures: 0, lastResult: .trusted))
        let ec = try verifier(root: Fixtures.ecRoot)
        XCTAssertTrue(verify(ec, try Fixtures.chain(Fixtures.ecServer, Fixtures.ecIntermediate)))
        XCTAssertEqual(ec.counters.snapshot().lastResult, .trusted)
    }

    func testRejectsUnknownRootEvenWhenThePeerSuppliesIt() throws {
        let system = try verifier(root: nil)
        XCTAssertFalse(verify(system, try Fixtures.chain(Fixtures.server, Fixtures.intermediate, Fixtures.root)))
        XCTAssertEqual(system.counters.snapshot(), TurnTLSTrustSnapshot(checks: 1, failures: 1, lastResult: .rejected))
    }

    func testRejectsExpiredWrongUsageBadSignatureAndMissingIntermediate() throws {
        for (name, leaf) in [
            ("expired", Fixtures.expired), ("clientonly", Fixtures.clientOnly),
            ("invalidsignature", Fixtures.invalidSignature),
        ] {
            let checked = try verifier()
            XCTAssertFalse(verify(checked, try Fixtures.chain(leaf, Fixtures.intermediate)), name)
            XCTAssertEqual(checked.counters.snapshot().lastResult, .rejected, name)
        }
        let leafOnly = try verifier()
        XCTAssertFalse(verify(leafOnly, try Fixtures.chain(Fixtures.server)))
        XCTAssertEqual(leafOnly.counters.snapshot().lastResult, .rejected)
        // The leaf-only callback is checked as a one-certificate chain, so it cannot validate without the
        // intermediate either.
        let legacy = try verifier()
        let leaf = try Fixtures.der(Fixtures.server)
        XCTAssertFalse(offMain { legacy.verify(leaf) })
        XCTAssertEqual(legacy.counters.snapshot(), TurnTLSTrustSnapshot(checks: 1, failures: 1, lastResult: .rejected))
    }

    func testRejectsMalformedAndOversizedInputBeforePlatformTrust() throws {
        let checked = try verifier(createTrust: { _, _ in
            XCTFail("platform trust must not be reached")
            return nil
        })
        let server = try Fixtures.der(Fixtures.server)
        let malformed: [[Data]] = [
            [], [Data()], [Data([1, 2, 3])], Array(repeating: Data([1]), count: 17),
            [Data(count: 1024 * 1024 + 1)], [server + Data([0])],
        ]
        for chain in malformed {
            XCTAssertFalse(verify(checked, chain))
            XCTAssertEqual(checked.counters.snapshot().lastResult, .invalidCertificate)
        }
        XCTAssertEqual(checked.counters.snapshot().checks, 6)
        XCTAssertEqual(checked.counters.snapshot().failures, 6)
    }

    func testTrustProviderFailureFailsClosedWithoutPrivateText() throws {
        let checked = try verifier(createTrust: { _, _ in nil })
        XCTAssertFalse(verify(checked, try Fixtures.chain(Fixtures.server, Fixtures.intermediate)))
        let snapshot = checked.counters.snapshot()
        XCTAssertEqual(snapshot, TurnTLSTrustSnapshot(checks: 1, failures: 1, lastResult: .unavailable))
        let reported = String(decoding: snapshot.json().encoded(), as: UTF8.self) + "\n" + snapshot.text()
        XCTAssertFalse(reported.contains("MicDrop"), reported)
        XCTAssertFalse(reported.contains("turn.invalid"), reported)
    }

    /// TURN/TLS decision of 2026-10-27: production uses Apple's platform trust only. The verifier `MediaEngine`
    /// builds (`TurnTLSTrustVerifier(counters:)`, `MediaEngine.swift:195`) sets no anchors, so SecTrust decides with
    /// the iOS trust store (system roots plus roots the user or device management trusts) and MicDrop adds no CA
    /// list, and no verify date, so it checks at the current time. A root the peer supplies is still no anchor.
    func testTheProductionEvaluatorSetsNoAnchorsAndNoVerifyDate() throws {
        let production = TurnTLSTrustVerifier(counters: TurnTLSTrustCounters())
        XCTAssertNil(production.evaluator.anchors, "no MicDrop CA list")
        XCTAssertNil(production.evaluator.verifyDate, "the current time")
        XCTAssertNil(TurnTLSTrustVerifier.Evaluator().anchors)
        XCTAssertNil(TurnTLSTrustVerifier.Evaluator().verifyDate)
        XCTAssertFalse(verify(production, try Fixtures.chain(Fixtures.server, Fixtures.intermediate, Fixtures.root)))
        XCTAssertEqual(
            production.counters.snapshot(), TurnTLSTrustSnapshot(checks: 1, failures: 1, lastResult: .rejected))
    }

    func testExposesTheSelectorsTheSDKAdapterCalls() {
        let checked = TurnTLSTrustVerifier(counters: TurnTLSTrustCounters())
        XCTAssertTrue(checked.responds(to: NSSelectorFromString("verifyChain:")))
        XCTAssertTrue(checked.responds(to: NSSelectorFromString("verify:")))
    }
}
