import Foundation

/// Default-output follow policy with speaker protection (`DefaultOutputPolicy.kt:12-51`).
///
/// "Worker and route callbacks serialize this with the receiver's audio lock. This hold never
/// changes user silence, microphone consent/mute, or the peer." Not internally synchronized.
public final class DefaultOutputPolicy: @unchecked Sendable {
    private var followsDefault: Bool
    private var protectSpeaker: Bool
    private var stopped = false
    /// `.route` initially while following the default route, else nil.
    public private(set) var pause: OutputPause?

    public init(_ initial: OutputSelection, protectedSpeaker: Bool = false) {
        let follows = !initial.explicit
        followsDefault = follows
        protectSpeaker = protectedSpeaker
        pause = follows ? .route : nil
    }

    /// Labeled spelling of (`DefaultOutputPolicy(initial:protectedSpeaker:)`).
    public convenience init(initial: OutputSelection, protectedSpeaker: Bool = false) {
        self.init(initial, protectedSpeaker: protectedSpeaker)
    }

    /// `followsDefault && protectSpeaker` (reported to the service as `protectedSpeaker`).
    public var speakerProtected: Bool { followsDefault && protectSpeaker }

    /// `stopped || pause != nil`.
    public var held: Bool { stopped || pause != nil }

    /// "Inventory only explains this existing hold; it never verifies a route or releases audio."
    /// `.bluetooth` when protected, no Bluetooth output is present and the pause is ROUTE/UNAVAILABLE.
    public func pauseForInventory(bluetoothAvailable: Bool) -> OutputPause? {
        if speakerProtected && !bluetoothAvailable && (pause == .route || pause == .unavailable) { return .bluetooth }
        return pause
    }

    /// New selection: PHONE clears protection; returning to DEFAULT with
    /// `protectSpeakerOnReturn` re-arms it; pause = `.route` iff following the default route.
    public func select(_ selection: OutputSelection, protectSpeakerOnReturn: Bool = false) {
        if stopped { return }
        followsDefault = !selection.explicit
        if selection.kind == .phone { protectSpeaker = false }
        if followsDefault && protectSpeakerOnReturn { protectSpeaker = true }
        pause = followsDefault ? .route : nil
    }

    /// Route changing: hold with `.route`.
    public func changing() {
        if !stopped && followsDefault { pause = .route }
    }

    /// External output removed ("becoming noisy"): protect the speaker and hold with `.route`.
    public func noisy() {
        if !stopped && followsDefault {
            protectSpeaker = true
            pause = .route
        }
    }

    /// Output unavailable: hold with `.unavailable`.
    public func unavailable() {
        if !stopped && followsDefault { pause = .unavailable }
    }

    /// Actual route kinds (nil/empty = unknown -> `.route`); any Bluetooth kind protects the
    /// speaker; a protected route containing PHONE holds with `.bluetooth`, else releases.
    public func observe(_ kinds: [OutputKind]?) {
        if stopped || !followsDefault { return }
        guard let kinds, !kinds.isEmpty else {
            pause = .route
            return
        }
        if kinds.contains(where: { $0.isBluetooth }) { protectSpeaker = true }
        pause = (protectSpeaker && kinds.contains(.phone)) ? .bluetooth : nil
    }

    /// Permanent; `pause` is not cleared, so `held` stays true.
    public func stop() { stopped = true }
}
