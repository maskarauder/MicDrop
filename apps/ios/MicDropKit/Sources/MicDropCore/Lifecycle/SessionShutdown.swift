// Teardown ordering helper. Port of `SessionShutdown.complete` (`SessionLifecycle.kt:161-170`, step 7). Synchronous per
// (the worker thread blocks in its own waits).

/// Remote notification precedes native destruction so a normal Stop does not race the host's ICE
/// watchdog; media is always released, even when notification fails.
public enum SessionShutdown {
    /// Calls `notifyRemote` (any thrown error counts as "not acknowledged"), then always `releaseMedia`.
    /// The caller has already muted local output (`StreamReceiving.close`). Returns the acknowledgment.
    ///
    /// - Parameters:
    ///   - notifyRemote: sends `/stop` or `/cancel-offer` (or nothing) and returns whether Windows
    ///     acknowledged it.
    ///   - releaseMedia: disposes peer, tracks, factory, ADM and routes in the documented order; handles its
    ///     own failures (teardown failure text belongs to the worker).
    public static func complete(notifyRemote: () throws -> Bool, releaseMedia: () -> Void) -> Bool {
        var acknowledged = false
        do {
            acknowledged = try notifyRemote()
        } catch {
            acknowledged = false
        }
        releaseMedia()
        return acknowledged
    }
}
