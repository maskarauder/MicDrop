// Output-related phase rules shared by the session worker, both session controllers and the UI
// (`StreamReceiver.kt:687-689`, `MainActivity.kt:1189-1191`).

extension SessionPhase {
    /// A retained playback-capable session accepts an output choice in PLAYING, RECOVERING,
    /// ROUTE_RECOVERING, PAUSED and INTERRUPTED (`MainActivity.kt:1189-1191`, `MicrophoneService.kt:273-275`).
    /// SWITCHING (a newly requested output or a microphone change being applied), CONNECTING, PAUSING and
    /// STOPPING refuse it.
    ///
    /// `ControlsDeriver` and both session controllers use this one rule, so an enabled output chooser is never
    /// refused. iOS difference: `PlaybackService.kt:76-78` omits ROUTE_RECOVERING, which Android playback
    /// never reaches; iOS playback reaches it while a selected output recovers or the default route is probed,
    /// and a replacement must stay selectable there (the system picker is disabled while an output is pinned).
    public var acceptsOutputChoice: Bool {
        switch self {
        case .playing, .recovering, .routeRecovering, .paused, .interrupted: return true
        case .idle, .connecting, .pausing, .switching, .stopping, .ended: return false
        }
    }

    /// Worker phase published after each heartbeat (`StreamReceiver.kt:687-689`), first match:
    /// 1. SWITCHING while a newly requested explicit output is verified
    ///    (`outputSwitchPending && !selectedOutputRecovering`);
    /// 2. ROUTE_RECOVERING while the existing selection recovers (`selectedOutputRecovering`: the selected
    ///    Bluetooth restore or the speaker repair) or `routeRecovering` holds (headset microphone recovery, or
    ///    the iOS default-route probing); Android publishes only the headset case here;
    /// 3. PLAYING when `healthy`, else RECOVERING.
    ///
    /// The phase only describes the output gates, which stay closed until the actual route verifies. Unlike
    /// SWITCHING, ROUTE_RECOVERING accepts an output choice (`acceptsOutputChoice`), so a lost pinned output
    /// can be replaced before its recovery window ends.
    public static func heartbeat(
        outputSwitchPending: Bool, selectedOutputRecovering: Bool, routeRecovering: Bool, healthy: Bool
    ) -> SessionPhase {
        if outputSwitchPending && !selectedOutputRecovering { return .switching }
        if selectedOutputRecovering || routeRecovering { return .routeRecovering }
        return healthy ? .playing : .recovering
    }

    /// iOS addition to the controllers' lease policy: ROUTE_RECOVERING keeps the background lease while a media output
    /// is restored or re-probed, i.e. while playback is held by an output pause (`.selectedBluetooth` for the selected
    /// Bluetooth restore, `.route` for the iPhone-speaker repair or default-route probing, `.bluetooth` /
    /// `.unavailable` while the default route is re-probed). Until `heartbeat` published the selection's recovery here
    /// it was SWITCHING, which is leased; the worker may stop and restart playout during it (`recreateOutput`), and a
    /// background app whose audio I/O stopped is suspended within seconds (fact 1). This rule covers output pauses
    /// only: duplex headset-microphone recovery keeps playout running silenced, and the microphone controller
    /// additionally leases microphone-only headset recovery, where capture is paused and no audio I/O runs. The lease
    /// expiry handlers act only in CONNECTING, and iOS bounds the lease itself (typically about 30 s).
    public func leasesOutputRecovery(pause: OutputPause?) -> Bool {
        self == .routeRecovering && pause != nil
    }
}
