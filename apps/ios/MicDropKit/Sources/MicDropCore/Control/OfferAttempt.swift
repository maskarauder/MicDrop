import Foundation

/// The per-worker offer nonce (`A/OfferAttempt.kt`). Created once per session worker with `supported = link version >=
/// 2`; never persisted or logged. The same nonce covers every busy retry of that worker; a later Connect builds a new
/// worker and a new nonce.
public final class OfferAttempt: @unchecked Sendable {
    /// Header name, verbatim (`A/OfferAttempt.kt:19`).
    public static let header = ControlRequest.Header.offerAttempt
    /// Paths that carry the nonce.
    public static let paths: Set<String> = [ControlRequest.Path.offer, ControlRequest.Path.cancelOffer]

    public let supported: Bool
    private struct State {
        var nonce: String
        var started = false
    }
    private let state: Locked<State>

    /// Production: a fresh CSPRNG nonce.
    public convenience init(supported: Bool) {
        self.init(supported: supported, nonce: OfferAttempt.randomNonce())
    }

    /// Tests: a fixed nonce (e.g. `attemptNonce(1)` = `AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE`).
    public init(supported: Bool, nonce: String) {
        self.supported = supported
        self.state = Locked(State(nonce: nonce))
    }

    /// True once the first `/offer` attempt began.
    public var started: Bool { state.value.started }

    /// Called before every `/offer` attempt, including busy retries.
    public func begin() {
        state.withLock { $0.started = true }
    }

    /// The nonce iff `supported && started && path ∈ {/offer, /cancel-offer}`.
    public func header(for path: String) -> String? {
        state.withLock { value in
            guard supported, value.started, OfferAttempt.paths.contains(path) else { return nil }
            return value.nonce
        }
    }

    /// `/cancel-offer` is needed iff `supported && started && sessionToken == nil`.
    public func needsCancellation(_ sessionToken: String?) -> Bool {
        supported && started && sessionToken == nil
    }

    /// An acknowledged cancellation tombstone retires the old attempt before fallback allocation.
    /// Explicit busy retries keep the same nonce; a failed cancellation never rotates it.
    public func cancelledForFallback(acknowledged: Bool) throws {
        try state.withLock { value in
            guard supported, value.started, acknowledged else { throw ControlResponseError(.invalidReply) }
            value.nonce = Self.randomNonce()
            value.started = false
        }
    }

    /// Unpadded base64url of 32 bytes from `SystemRandomNumberGenerator` (a CSPRNG on Darwin
    /// and Linux): 43 characters.
    public static func randomNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        var text = ""
        for character in Data(bytes).base64EncodedString() {
            switch character {
            case "+": text.append("-")
            case "/": text.append("_")
            case "=": continue
            default: text.append(character)
            }
        }
        return text
    }
}
