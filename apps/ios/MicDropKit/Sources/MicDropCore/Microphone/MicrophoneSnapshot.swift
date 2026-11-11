import Foundation

/// The `/status` report `microphone` object and its copy-report line (`A/MicrophoneInput.kt:10-19`, Go
/// `G/diagnostics/report.go:63-71`, `:163-184`).
///
/// Every report of a microphone session carries it; playback-only reports must not.
/// `processing` is the *effective* `MicrophoneProcessing` and is set only when the offer
/// advertised `microphone_processing_version == 1` (`A/StreamReceiver.kt:717`).
/// Values never contain device identity (route labels are fixed).
///
/// Two equivalent encodings are offered: `json()` (explicit `DiagnosticJSON`) and
/// `Encodable` (wire keys via `CodingKeys`, nil members omitted like Android's `fields()`),
/// for `DiagnosticJSON(encoding:)`.
public struct MicrophoneSnapshot: Equatable, Sendable, Encodable {
    /// `microphone.state` vocabulary (`report.go`: `running|muted|waiting`).
    public enum State: String, CaseIterable, Sendable {
        case running
        case muted
        case waiting
    }

    /// What the app reads from the active capture. `nil` capture means "capture object unavailable": ADM recording
    /// paused / not initialized, or session inactive.
    public struct CaptureReading: Equatable, Sendable {
        /// `AVAudioSession.currentRoute.inputs.first`.
        public let routedInput: AudioPortDescriptor?
        /// `Int(AVAudioSession.sampleRate.rounded())`.
        public let sampleRateHz: Int
        /// The ADM recording format: always 1 on iOS (never `inputNumberOfChannels`).
        public let channels: Int
        /// `MicrophoneRouting.matchesInput(routedInput)` (selection match plus the Bluetooth communication-route
        /// check).
        public let inputMatches: Bool

        public init(routedInput: AudioPortDescriptor?, sampleRateHz: Int, channels: Int = 1, inputMatches: Bool) {
            self.routedInput = routedInput
            self.sampleRateHz = sampleRateHz
            self.channels = channels
            self.inputMatches = inputMatches
        }
    }

    /// `running`, `muted` or `waiting`.
    public let state: String
    /// A `MicrophoneKind.label` or `"unavailable"`.
    public let route: String
    /// Actual capture rate; 0 when unknown (0 … 384000).
    public let sampleRate: Int
    /// Capture channels; 0 when unknown (0 … 2).
    public let channels: Int
    /// The selection's kind label; always sent by this client.
    public let requestedRoute: String?
    /// Always sent by this client.
    public let routeVerified: Bool?
    /// Effective processing, only when `microphone_processing_version == 1`.
    public let processing: MicrophoneProcessing?

    /// Wire keys (`report.go:63-71`), in Android `fields()` order.
    private enum CodingKeys: String, CodingKey {
        case state
        case route
        case sampleRate = "sample_rate_hz"
        case channels
        case requestedRoute = "requested_route"
        case routeVerified = "route_verified"
        case processing
    }

    public init(
        state: String, route: String, sampleRate: Int = 0, channels: Int = 0,
        requestedRoute: String? = nil, routeVerified: Bool? = nil,
        processing: MicrophoneProcessing? = nil
    ) {
        self.state = state
        self.route = route
        self.sampleRate = sampleRate
        self.channels = channels
        self.requestedRoute = requestedRoute
        self.routeVerified = routeVerified
        self.processing = processing
    }

    /// Copy with `processing` replaced (report assembly adds it when negotiated).
    public func with(processing: MicrophoneProcessing?) -> MicrophoneSnapshot {
        MicrophoneSnapshot(
            state: state, route: route, sampleRate: sampleRate, channels: channels,
            requestedRoute: requestedRoute, routeVerified: routeVerified, processing: processing)
    }

    /// The `state` argument of the snapshot builder (`A/StreamReceiver.kt:710-713`):
    /// `waiting` if network audio is held or headset recovery is pending; else `muted` if the
    /// applied mute is `true`; else `running` if capture has started; else `waiting`.
    public static func reportState(
        networkHeld: Bool, recoveryPending: Bool, appliedMuted: Bool?,
        recordStarted: Bool
    ) -> String {
        if networkHeld || recoveryPending { return State.waiting.rawValue }
        if appliedMuted == true { return State.muted.rawValue }
        return recordStarted ? State.running.rawValue : State.waiting.rawValue
    }

    /// `MicrophoneInput.snapshot` (`A/MicrophoneInput.kt:42-55`), ported exactly: without a capture reading → `(running
    /// ? waiting : state)`, `unavailable`, 0 Hz, 0 channels, requested = selection label, verified = false. With one (a
    /// non-nil reading already means capture is running, Android `captureRunning`) → route = label of the routed
    /// input's type (`unavailable` when absent, not an input, or not a microphone kind); verified = `state ∈ {running,
    /// muted} && inputMatches`; state = `running && !verified ? waiting : state`. A capture kept open while muted (the
    /// background keep-alive, or the one report after a background network hold before the next apply) is therefore
    /// `muted` with `route_verified: true` when its live routed input matches: muted describes transmission, not
    /// whether verified capture is retained. `waiting` and a nil capture are never verified. This is diagnostics only;
    /// no gate, `/microphone` request or capture start/stop depends on it.
    ///
    /// iOS host-consistency guards (a value the host rejects would disable uploads for the whole session,
    /// `report.go:163-184`). They never change a consistent Android-shaped reading: `verified` additionally requires
    /// `channels == 1` (never `running` with two channels), `sample_rate_hz >= 8000` and `route == requested_route`; a
    /// rate outside 0…384000 or a channel count outside 0…2 is reported as 0 ("unknown"), never invented.
    public static func make(
        state: String, selection: MicrophoneSelection, capture: CaptureReading?,
        processing: MicrophoneProcessing? = nil
    ) -> MicrophoneSnapshot {
        let running = State.running.rawValue
        let muted = State.muted.rawValue
        let waiting = State.waiting.rawValue
        let requested = selection.kind.label
        guard let capture else {
            return MicrophoneSnapshot(
                state: state == running ? waiting : state,
                route: MicrophoneKind.unavailableRouteLabel,
                requestedRoute: requested, routeVerified: false,
                processing: processing)
        }
        let routed: AudioPortDescriptor? = capture.routedInput?.isInput == true ? capture.routedInput : nil
        let route = MicrophoneKind.routeLabel(portTypeRaw: routed?.type)
        let rate = (0...maximumSampleRateHz).contains(capture.sampleRateHz) ? capture.sampleRateHz : 0
        let channels = (0...maximumChannels).contains(capture.channels) ? capture.channels : 0
        let verified =
            (state == running || state == muted) && capture.inputMatches && route == requested
            && rate >= minimumRunningSampleRateHz && channels == 1
        return MicrophoneSnapshot(
            state: state == running && !verified ? waiting : state,
            route: route, sampleRate: rate, channels: channels,
            requestedRoute: requested, routeVerified: verified,
            processing: processing)
    }

    /// Host bounds (`report.go:170-179`): `0 ≤ sample_rate_hz ≤ 384000`, `0 ≤ channels ≤ 2`, and a
    /// `running` (or verified) microphone needs at least 8000 Hz.
    public static let maximumSampleRateHz = 384_000
    public static let maximumChannels = 2
    public static let minimumRunningSampleRateHz = 8000

    /// `fields()` + optional `processing`, as an ordered report object:
    /// `state`, `route`, `sample_rate_hz`, `channels`, [`requested_route`], [`route_verified`],
    /// [`processing`].
    public func json() -> DiagnosticJSON {
        var members: [(key: String, value: DiagnosticJSON)] = [
            (key: "state", value: .string(state)),
            (key: "route", value: .string(route)),
            (key: "sample_rate_hz", value: .int(Int64(sampleRate))),
            (key: "channels", value: .int(Int64(channels))),
        ]
        if let requestedRoute { members.append((key: "requested_route", value: .string(requestedRoute))) }
        if let routeVerified { members.append((key: "route_verified", value: .bool(routeVerified))) }
        if let processing { members.append((key: "processing", value: processing.json())) }
        return .object(members)
    }

    /// `text()` (`A/MicrophoneInput.kt:17-18`):
    /// `Microphone: <state> · Input: <route> · <rate> Hz / <channels> channels` and, when a
    /// requested route exists, `\nSelected input: <requested> · Route verified: <true|false>`.
    public func text() -> String {
        var line = "Microphone: \(state) · Input: \(route) · \(sampleRate) Hz / \(channels) channels"
        if let requestedRoute {
            line += "\nSelected input: \(requestedRoute) · Route verified: \(routeVerified == true)"
        }
        return line
    }

    /// Host acceptance rules (`G/diagnostics/report.go:163-184`) as a Swift validator for
    /// tests and a debug assertion before upload: returns the first violated rule's field
    /// name, or nil when the host would accept this object. `audioDirection` is the report's
    /// top-level `audio_direction` (`"duplex"` only for duplex reports, else `""`). A verified
    /// route needs route == requested, ≥ 8000 Hz and one channel in every state: muted describes
    /// transmission, not whether verified capture is retained (`:176-178`).
    public func hostValidationProblem(audioDirection: String) -> String? {
        let labels = MicrophoneKind.routeLabels
        let requested = requestedRoute ?? ""
        if let processing {
            if processing.echoCancellation && audioDirection != "duplex" {
                return "processing.echo_cancellation_requested"
            }
            if (processing.echoCancellation || processing.noiseReduction) && requested.hasPrefix("Bluetooth") {
                return "processing"
            }
        }
        if State(rawValue: state) == nil { return "state" }
        if !(labels.contains(route) || route == MicrophoneKind.unavailableRouteLabel) { return "route" }
        if sampleRate < 0 || sampleRate > Self.maximumSampleRateHz { return "sample_rate_hz" }
        if channels < 0 || channels > Self.maximumChannels { return "channels" }
        let isRunning = state == State.running.rawValue
        let lowRate = sampleRate < Self.minimumRunningSampleRateHz
        if isRunning && (route == MicrophoneKind.unavailableRouteLabel || lowRate || channels != 1) {
            return "state"
        }
        if !requested.isEmpty || routeVerified != nil {
            guard labels.contains(requested) else { return "requested_route" }
            guard let verified = routeVerified else { return "route_verified" }
            if verified && (route != requested || lowRate || channels != 1) {
                return "route_verified"
            }
            if isRunning && !verified { return "route_verified" }
        } else if !(route == MicrophoneKind.builtIn.label || route == MicrophoneKind.unavailableRouteLabel) {
            return "route"
        }
        return nil
    }
}
