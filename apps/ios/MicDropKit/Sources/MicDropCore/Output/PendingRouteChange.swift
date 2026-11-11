import Foundation

/// One pending foreground replacement of a live stream (`PendingRouteChange.kt:3-23`). Consumed by the microphone
/// input-switch flow.
///
/// "A single foreground selection replaces a current stream after its worker has ended. No queue,
/// durable restart ticket or consent survives cancellation." Main-actor owned; not synchronized.
public final class PendingRouteChange<T> {
    /// Replacement window (`PendingRouteChange.kt:5`, 20 000 ms).
    public let limitMs: Int64
    private var origin: String?
    private var value: T?
    private var deadline: Int64 = 0

    public init(limitMs: Int64 = 20_000) {
        self.limitMs = limitMs
    }

    /// Starts a replacement for session `id`; false while another is pending.
    @discardableResult
    public func begin(_ id: String, _ target: T, nowMs: Int64) -> Bool {
        if origin != nil { return false }
        origin = id
        value = target
        deadline = nowMs + limitMs
        return true
    }

    /// `origin == id`.
    public func matches(_ id: String) -> Bool { origin == id }

    /// `origin != nil && now >= deadline`.
    public func expired(nowMs: Int64) -> Bool { origin != nil && nowMs >= deadline }

    /// The target for `id` unless expired; always cancels when `id` matches.
    public func take(_ id: String, nowMs: Int64) -> T? {
        guard matches(id) else { return nil }
        let target: T? = expired(nowMs: nowMs) ? nil : value
        cancel()
        return target
    }

    public func cancel() {
        origin = nil
        value = nil
        deadline = 0
    }
}

/// "An old notification can only Stop or Mute its own in-flight replacement." (`PendingRouteChange.kt:25-30`). Pure;
/// used for any action that carries a session generation token.
public enum RouteActionScope {
    /// `current != nil && requested != nil && (current == requested || (safetyOnly &&
    /// requested == replacing && phase ∈ {switching, connecting, recovering, routeRecovering}))`.
    public static func accepts(
        current: String?, requested: String?, replacing: String?,
        phase: SessionPhase, safetyOnly: Bool
    ) -> Bool {
        guard let current, let requested else { return false }
        if current == requested { return true }
        let replacementPhases: [SessionPhase] = [.switching, .connecting, .recovering, .routeRecovering]
        return safetyOnly && requested == replacing && replacementPhases.contains(phase)
    }
}
