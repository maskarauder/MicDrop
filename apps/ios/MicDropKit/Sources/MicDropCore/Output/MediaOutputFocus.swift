import Foundation

/// Duplex media-output focus pause labels (`DefaultOutputPolicy.kt:72-85`).
///
/// "Permanent focus loss requires an explicit grant even after later transient callbacks.": on iOS every duplex
/// interruption follows Path B (pause both directions), so this type is kept as pure, tested code but is never driven
/// by the iOS app.
public final class MediaOutputFocus: @unchecked Sendable {
    public private(set) var pause: OutputPause?

    public init() {}

    /// Manual (permanent) loss -> `.focusManual`; automatic (transient) loss -> `.focus` unless
    /// a manual loss is already pending.
    public func lose(automatic: Bool) {
        if !automatic { pause = .focusManual } else if pause != .focusManual { pause = .focus }
    }

    /// Clears only a transient `.focus` pause; returns whether it did.
    public func gain() -> Bool {
        if pause != .focus { return false }
        pause = nil
        return true
    }

    /// Explicit grant (user re-enabled output): clears any pause.
    public func granted() { pause = nil }
}
