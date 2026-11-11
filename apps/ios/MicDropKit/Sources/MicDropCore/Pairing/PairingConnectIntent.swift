import Foundation

/// One-shot "continue Connect after approved pairing" intent (exact port of Android `PairingConnectIntent.kt:6-18`;:
/// one copy, owned here).
///
/// A visible Connect may continue its own approved and durably saved pairing exactly once. Loading an old pairing,
/// scanning or observing service state never creates it; it is not persisted. Callers (UI, main actor):
/// `begin(store.pair(text, label))` when Connect routes to pairing; `cancel()` on any new connect, Stop, Cancel
/// pairing, Forget and when the scene enters `.background` (never on `.inactive`); `take(...)` on every saved-view
/// publish, scene `.active` and controller readiness.
public final class PairingConnectIntent {
    private var operation: Int64?

    public init() {}

    /// True while an operation id is held.
    public var pending: Bool { operation != nil }

    /// Holds `id` when it is positive, else clears (`id?.takeIf { it > 0 }`).
    public func begin(_ id: Int64?) {
        if let id, id > 0 {
            operation = id
        } else {
            operation = nil
        }
    }

    public func cancel() {
        operation = nil
    }

    /// Returns true exactly once, when the saved pairing for the held operation is confirmed
    /// (`successID == operation`, not `working`, `available`) and the screen is `visibleReady`.
    /// A failed, cancelled, stale or unavailable result clears the intent; waiting for
    /// visibility keeps it.
    public func take(successID: Int64, working: Bool, available: Bool, visibleReady: Bool) -> Bool {
        guard let expected = operation else {
            return false
        }
        if working {
            return false
        }
        if successID != expected || !available {
            cancel()
            return false
        }
        if !visibleReady {
            return false
        }
        cancel()
        return true
    }
}
