import Foundation

/// Verbatim UI string catalogue of the main screen (`res/values/strings.xml`, hard-coded `MainActivity.kt` texts), with
/// the iOS texts of applied.
///
/// Strings owned by other subsystems are not repeated here: `SessionPhase.label`, `StopReason.message` (07),
/// `OutputPause.detail`, `OutputKind.label` (09), `MicrophoneKind.label`, `MicrophoneRouteProblem.detail` (08),
/// `SavedConnectionView` / pairing progress texts (01), `ConnectionFailure.describe` (02), local probe end
/// messages (04). Unicode is exact: `…` U+2026, `·` U+00B7, `▾` U+25BE, `▸` U+25B8, `→` U+2192.
public enum Strings {
    // MARK: strings.xml (line numbers in parentheses)
    // Updated Android strings cite `strings.xml:NN` and `MainActivity.kt:NNNN` lines at that revision.

    public static let appName = "MicDrop"  // (6, 7)
    public static let subtitle = "Listen to Windows. Send your microphone back."  // (8)
    public static let connectionSetup = "Connection setup"  // (9)
    public static let audioOutput = "Audio output"  // (10)
    public static let chooseOutput = "Choose media output"  // (11)
    /// `selected_output` (12).
    public static func selectedOutput(_ title: String) -> String { "Media output: \(title)" }
    /// `next_media_output` (13).
    public static func nextMediaOutput(_ title: String) -> String { "Media output after headset mic: \(title)" }
    /// `output_reselect` (14), iOS text: Android's "Device missing?" becomes the picker row and Stop (D042).
    public static let outputReselect = SessionLifecycle.Messages.outputReselect
    /// Message of the media output dialog, iOS port of `bluetooth_device_help` (`strings.xml:38`, D042): the
    /// dialog cannot carry the picker, so it points to the picker row. `ControlsRender.outputDialogMessage`
    /// appends the picker caption while the picker is disabled.
    public static let outputDialogMessage =
        "iOS lets MicDrop list only outputs in the current iPhone route. If a connected device is missing, make it "
        + "the iPhone output with AirPlay & Bluetooth output…, then choose it here to remember it. "
        + "Your current MicDrop choice stays saved."
    // (15)
    public static let outputChangeUnavailable =
        "The output could not be changed. Choose a connected media output after the current audio setup finishes."
    // (16)
    public static let inputChangeUnavailable =
        "The microphone could not be changed. Check its connection and permissions, and choose a media output before changing to a phone, wired or USB microphone."
    public static let microphone = "Microphone"  // (17)
    public static let advanced = "Advanced"  // strings.xml:20
    /// `advanced_help` (`strings.xml:21`).
    public static let advancedHelp = "Connection order and timeouts apply the next time you connect."
    /// `advanced_summary` (`strings.xml:22`); `recoverySeconds` is `ConnectionPreferences.seconds` of the saved
    /// recovery window (Android `ConnectionTimeout.seconds`, `MainActivity.kt:1388-1389`).
    public static func advancedSummary(recoverySeconds: String) -> String {
        "Recovery window: \(recoverySeconds) s · Connection and host controls"
    }
    public static let diagnostics = "Diagnostics"  // strings.xml:25
    /// `diagnostics_help` (`strings.xml:26`), ADAPTED ("this iPhone").
    public static let diagnosticsHelp =
        "Copy a report when troubleshooting, or check playback on this iPhone without connecting to Windows."
    public static let sectionExpanded = "Expanded"  // (19)
    public static let sectionCollapsed = "Collapsed"  // (20)
    public static let enableAudio = "Play desktop audio"  // (21)
    public static let enableAudioPaused = "Play desktop audio (paused)"  // (22)
    /// `use_phone_speaker` (23): [09] status-card action.
    public static let usePhoneSpeaker = "Use iPhone speaker"
    /// `follow_android_output` (24): [09] status-card action.
    public static let followSystemOutput = "Follow iPhone media output"
    public static let enableMicrophone = "Send microphone"  // (25)
    public static let pause = "Pause playback"  // (26)
    public static let cancelPairing = "Cancel pairing"  // (27)
    public static let changeAddress = "Change Windows address"  // (28, MainActivity.kt:1069)
    public static let forgetConnection = "Forget saved connection"  // (29)
    /// Replaces `android_sound_settings` (30): the `AVRoutePickerView` row.
    public static let routePickerRow = "AirPlay & Bluetooth output…"
    /// Caption while a session (Paused included) or setup with a pinned output disables the system picker: iOS version
    /// of `device_picker_stops_session` (`strings.xml:39`, D042).
    public static let routePickerPinnedCaption =
        "While a session or setup is in progress, a selected output ignores the system picker. "
        + "Tap Stop to use it; your choice stays saved. After choosing your device, tap Connect explicitly. "
        + "Microphone capture will not restart automatically."
    /// iOS caption while no session is retained and a pinned output is the current route: the picker stays
    /// enabled without changing or erasing the remembered device (D042).
    public static let routePickerIdlePinCaption =
        "Your selected output stays saved. If a connected device is missing from Choose media output, "
        + "make it the iPhone output with the system picker, then choose it there."
    /// iOS caption while no session is retained and a pinned output is not the current route (for example one
    /// remembered from an earlier launch): the picker stays enabled so iOS can make that device the route.
    public static let routePickerUnavailablePinCaption =
        "The selected output is not the current iPhone output. "
        + "Use the system picker to switch to it, or choose another media output."
    /// iOS caption while a Bluetooth headset microphone session (microphone-only or duplex) owns the route: a picker
    /// choice would move it. Mode-neutral, because a microphone-only session has no playback.
    public static let routePickerHeadsetCaption =
        "The selected headset microphone owns the audio route, and the system picker would move it. "
        + "Tap Stop to use the picker, then tap Connect explicitly."
    /// `playback_volume` (32), ADAPTED: volume label fallback and slider accessibility label.
    public static let playbackVolume = "Playback volume"
    /// `media_volume` (33), ADAPTED to a percentage.
    public static func mediaVolume(percent: Int) -> String { "Media volume · \(percent)%" }
    /// `voice_volume` (34), ADAPTED to a percentage.
    public static func voiceVolume(percent: Int) -> String { "Headset voice volume · \(percent)%" }
    public static let microphoneInput = "Choose microphone input"  // (35)
    /// `selected_microphone` (36).
    public static func selectedMicrophone(_ title: String) -> String { "Microphone input: \(title)" }
    public static let leStereo = "LE Audio stereo playback (experimental)"  // (37)
    /// `build_label` (38).
    public static func buildLabel(_ revision: String) -> String { "Build \(revision)" }
    /// `version_label` (`strings.xml:54`): the Diagnostics section summary (`MainActivity.kt:1390`).
    public static func diagnosticsSummary(versionName: String) -> String {
        "MicDrop \(versionName) · Reports and notices"
    }
    // (39) connection_help, strings.xml:55
    public static let connectionHelp =
        "In the Windows app, open Phones → Pair a phone. Scan its QR code or paste the link, tap Connect, then approve the request in Windows. Keep MicDrop open to connect after approval. If you leave the app, tap Reconnect when you return."
    /// `output_help` (40): text (10, adapted to 09).
    public static let outputHelp =
        "Turning this off silences desktop audio while keeping the connection open. On means playback is requested; paused means it is temporarily held. iPhone media output follows the system route; use AirPlay & Bluetooth output to change it. Losing Bluetooth pauses playback on iPhone-speaker fallback; the microphone keeps its current setting. Tap Use iPhone speaker for temporary speaker playback. When Bluetooth returns, iPhone media output resumes automatically. Follow iPhone media output remains available as a fallback. A device chosen in the output menu is only guarded: MicDrop pauses rather than play elsewhere."
    // (41)
    public static let headsetOutputHelp =
        "Playback follows the selected headset microphone. The media output choice applies after switching to a phone, wired or USB microphone. Turning audio off silences it without changing the headset route."
    // (42)
    public static let outputUnavailable =
        "Desktop audio was not enabled when this session started. Stop, enable audio, and reconnect to add listening."
    // (43)
    public static let microphoneHelp =
        "Turning this off during a microphone session mutes capture. Your choices are remembered; only an explicit Connect starts a new microphone session."
    public static let microphoneUnavailable =
        "This session started without a microphone. Stop, enable Send microphone, and reconnect to use it."  // (44)
    /// `microphone_reselect` (45); also the `requestMicrophone` failure.
    public static let microphoneReselect = "Choose your microphone input again before connecting."
    public static let microphoneUpdating = "Updating microphone…"  // (46)
    public static let noReport = "No stream report yet. Connection details will appear here."  // (47)
    public static let audioOn = "Audio on"  // (48)
    public static let audioSilenced = "Audio silenced"  // (49)
    public static let audioPaused = "Audio paused"  // (50)
    public static let microphoneOn = "Microphone on"  // (51)
    public static let microphoneMuted = "Microphone muted"  // (52)
    public static let microphoneOff = "Microphone off"  // (53)
    public static let invitationHint = "Paste the Windows invitation"  // (55)
    public static let connect = "Connect"  // (56)
    public static let findWindows = "Find Windows on LAN"  // (57)
    public static let stopDiscovery = "Stop searching"  // (58)
    /// `discovered_saved` (59).
    public static func discoveredSaved(host: String, port: Int) -> String {
        "Saved Windows candidate · \(host):\(port)"
    }
    /// `discovered_host` (60); `keyPrefix` is the first 12 characters of the key hint.
    public static func discoveredHost(keyPrefix: String, host: String, port: Int) -> String {
        "Windows · \(keyPrefix) · \(host):\(port)"
    }
    public static let discoveredConnectTitle = "Connect to saved Windows?"  // (61)
    /// `discovered_connect_message` (62).
    public static func discoveredConnectMessage(host: String, port: Int) -> String {
        "Try \(host):\(port) with your saved pairing. MicDrop checks the Windows identity before playing and remembers this address only after playback connects."
    }
    public static let discoveryPairTitle = "Pair with Windows first"  // (63)
    // (64) discovery_pair_first, strings.xml:80
    public static let discoveryPairFirst =
        "In the Windows app, open Phones → Pair a phone. Scan its QR code or paste the link, then tap Connect and approve the matching request in Windows. Finding a computer on your network does not pair it automatically."
    public static let discoveryPaste = "Paste invitation"  // (65)
    public static let scanPairing = "Scan pairing QR"  // (66)
    /// `scan_prompt` (67; `strings.xml:83`), ADAPTED (Cancel instead of Back).
    public static let scanPrompt = "Scan the entire pairing QR in the Windows app. Cancel returns to manual entry."
    public static let scanCameraDenied =
        "Camera access is only needed for scanning. You can paste the Windows link instead."  // (68)
    public static let scanCameraUnavailable = "Camera unavailable. Paste the Windows link instead."  // (69)
    public static let scanInvalid = "That QR code is not a valid MicDrop pairing invitation."  // (70)
    // (71) scan_expired, strings.xml:87
    public static let scanExpired = "That pairing QR expired. Select Pair a phone in Windows and scan the new code."
    public static let scanComplete = "Pairing invitation scanned. Tap Connect."  // (72)
    /// `scan_ready` (73).
    public static func scanReady(host: String, port: Int) -> String {
        "Scanned Windows at \(host):\(port). Tap Connect, then approve the matching request in Windows."
    }
    public static let copyDiagnostics = "Copy last stream report"  // (74)
    public static let copyCrashDiagnostics = "Copy crash report"  // (75)
    public static let crashDiagnosticsCopied = "Crash diagnostics copied. Keep this report private."  // (76)
    public static let diagnosticsCopied = "Playback snapshot copied. Host address and invitation excluded."  // (77)
    // (78)
    public static let invalidInvitation = "Paste the complete Windows pairing or connection link, then tap Connect."
    public static let connectionLinkExpired = "This connection link has expired."  // (79)
    public static let connectionFailed = "The connection failed. Check the connection status."  // (80)
    public static let notices = "Open-source notices"  // (81)
    public static let localOutputTest = "Start local output test"  // (83)
    public static let playClick = "Play click"  // (84)
    public static let fastRecovery = "Faster recovery after audio interruptions"  // (85)
    // (86)
    public static let localOutputInstructions =
        "Tap Play click and listen for the response. This audio-only test uses matching streaming output settings. Tap-to-sound includes touch and scheduling delay; it is not a calibrated latency measurement. Stop, then connect to Windows to include this baseline in the combined log."
    public static let stop = "Stop"  // (87) stop, formerly stop_tone; strings.xml:103
    /// `focus_denied` (89); also the local-tool `AudioSessionOwner.tryAcquire()` failure.
    public static let focusDenied = "Audio is busy. Try again after other playback stops."
    public static let microphoneEcho = "Reduce microphone echo (experimental)"  // (2)
    public static let microphoneNoise = "Reduce microphone background noise"  // (3)
    // (4)
    public static let microphoneProcessingHelp =
        "Choose before connecting. Echo reduction can help with phone-speaker playback; headphones are still recommended. These options process only the microphone."
    /// `microphone_processing_bluetooth` (5), ADAPTED.
    public static let microphoneProcessingBluetooth =
        "Bluetooth microphone processing is managed by iOS and the headset. These options are retained for phone or wired/USB input."

    // MARK: Hard-coded MainActivity texts

    public static let connectionLinkExpiredDetail =
        "That connection link expired. Restart Windows and paste its new link."  // :701
    /// `MainActivity.kt:725`, [10].
    public static let connectStartFailed = "MicDrop could not start playback. Keep MicDrop open and try Connect again."
    public static let microphoneDialogTitle = "Microphone input"  // :733
    /// Replaces the Android "Bluetooth settings" button ([10]); iOS has no public Bluetooth-settings link. The second
    /// sentence is Android's caveat (`bluetooth_device_help`, `strings.xml:38`).
    public static let microphoneDialogMessage =
        "Connect Bluetooth headsets in iOS Settings, then choose them here. "
        + "A media output does not necessarily support microphone input."
    /// footer while a retained session hides Bluetooth inputs: a non-Bluetooth microphone session or a playback
    /// session, Paused included (appended to the dialog message). The text is owned by
    /// (`MicrophoneChoice.bluetoothUnavailableFooter`); this is the same value.
    public static let microphoneDialogBluetoothFooter = MicrophoneChoice.bluetoothUnavailableFooter
    public static let cancel = "Cancel"  // :740
    public static let ok = "OK"  // notices dialog
    /// Keyboard toolbar button that clears the invitation field focus (iOS-only).
    public static let done = "Done"
    /// `MainActivity.kt:742`, ADAPTED.
    public static let listInputsFailed =
        "iOS could not list microphone inputs. Check your headset connection and try again."
    public static let pairBeforeMicrophone = "Pair with Windows before using microphone return."  // :899
    // The record-permission denial text is `MicrophonePermissions.denial(kind:status:)` and the
    // "selected microphone is unavailable" text is `MicrophoneRouteProblem.unavailable.detail` (both 08).
    public static let microphoneStartFailed =
        "Microphone return could not start. Keep MicDrop open and check microphone permission."  // :951
    // :961
    public static let pairingInvitationExpired =
        "That pairing invitation expired. In the Windows app, open Phones → Pair a phone for a new one."
    public static let pairingInvitationInvalid = "Paste the pairing invitation from the paired Windows host."  // :971
    public static let connectionNeedsAttention = "Connection needs attention"  // :995
    public static let addressHostHint = "Windows private IPv4 address"  // :1063
    public static let addressPortHint = "Port"  // :1065
    public static let changeAddressMessage =
        "Use the same paired Windows computer. Its identity will still be checked when connecting."  // :1070
    public static let saveAddress = "Save address"  // :1072
    public static let addressInvalid = "Use a private IPv4 address and a port from 1 to 65535."  // :1080
    /// `MainActivity.kt:1099`; `uptimeMs` from `MonotonicClock.nowMs()`.
    public static func localOutputBaselineHeader(uptimeMs: Int64) -> String {
        "Local output baseline · phone uptime \(uptimeMs) ms"
    }
    public static let unavailableSuffix = " (unavailable)"  // :1202, :1227
    // :1229
    public static let inputHelpLEStereo =
        "LE Audio stereo playback selected. Changing input or profile briefly reconnects the stream. Echo cancellation is off."
    // :1230
    public static let inputHelpLEMono =
        "LE Audio mono compatibility playback selected. Changing input or profile briefly reconnects the stream. Echo cancellation is off."
    // :1231
    public static let inputHelpSCO =
        "This Bluetooth microphone uses mono voice playback. Choose the phone microphone for high-quality media listening; input changes briefly reconnect."
    // :1232
    public static let inputHelpDefault =
        "Input changes briefly reconnect the stream. Use headphones, or try microphone echo reduction when listening through the phone speaker."
    /// `MainActivity.kt:1234`. The two Android LE suffixes are omitted on iOS (ADAPTED).
    public static let inputHelpUncheckedSuffix =
        "\nInput availability could not be checked. Tap Microphone input to retry."
    public static let resumeDuplex = "Resume duplex"  // :1254
    public static let connecting = "Connecting…"  // :1255
    public static let reconnect = "Reconnect"  // :1256
    public static let keepPaused = "Keep paused"  // :1276
    public static let selectedHeadset = "selected headset"  // :1283
    public static let crashInformationUnavailable = "Crash information unavailable."  // :479
    /// iOS-only replacement of "Android has no retained MicDrop crash record.".
    public static let crashRecordUnavailable = "iOS has no retained MicDrop crash record."
    /// iOS-only status-card / discovery link.
    public static let openSettings = "Open Settings"
    /// Default notice of `showConnectionFailure` / `showConnectionNotice` (`MainActivity.kt:992-1003`).
    public static let defaultFailureNotice = connectionFailed

    /// Collapsible section header text: two spaces, then `▾` (expanded) or `▸` (collapsed)
    /// (`SettingsSection.kt:43`).
    public static func sectionHeader(_ title: String, expanded: Bool) -> String {
        title + (expanded ? "  ▾" : "  ▸")
    }

    // MARK: Advanced section: phone settings exchange v1 (D046; `MainActivity.kt:463-468`, `:499-511`)

    /// The phone-local opt-in, verbatim (`allow_windows_settings`, `strings.xml:23`): Windows asks the user to
    /// enable exactly this option (`internal/desktop/phone_settings_windows.go:278`).
    public static let allowWindowsSettings = "Allow Windows to change phone settings"
    /// `windows_settings_help` (`strings.xml:24`), ADAPTED: iOS has no public API to set the iPhone volume, so Windows
    /// gets no volume control (Android's "phone volume" is dropped and a sentence says why), and a sentence adds the
    /// unmute rule (`MicrophoneView.offersPhoneControlMute`): Windows unmutes only a microphone that was already on
    /// during this connection, while access is allowed, and in the background only one already kept active while muted.
    /// Android's "audio output" is named as the iPhone's two controls (media output and Play desktop audio), and a
    /// media output change applies at once in a session that plays through media output (`PhoneOutputControl`; a
    /// Bluetooth headset microphone or a microphone-only session keeps it for later). "this phone" reads "this iPhone".
    public static let allowWindowsSettingsHelp =
        "While connected, your paired Windows host can adjust Audio and Advanced preferences, media output, Play "
        + "desktop audio and microphone mute. Pairing and microphone consent stay on this iPhone. A media output "
        + "change applies at once when desktop audio uses media output; other changes apply after Stop and Connect. "
        + "Windows can unmute the microphone only after it has been on during this connection and while "
        + "microphone access is allowed; while MicDrop is in the background, only if it was kept active while muted. "
        + "iOS does not let apps set the iPhone volume. These controls are unavailable while paused or disconnected."
    /// iOS-only: the opt-in file could not be written, so the previous choice stays in effect.
    public static let allowWindowsSettingsSaveFailed = "Could not save this setting. Try again."
    /// iOS-only: the single button that opens the Connection settings sheet (`ConnectionPolicyView`). Android shows
    /// one button per `ConnectionSettingsGroup` (`MainActivity.kt:503-508`); the iPhone keeps all groups in one sheet.
    public static let connectionSettings = "Connection settings"

    // MARK: Status card (`MainActivity.kt:1311-1347`)

    public static let statusLocalTest = "Local audio test"
    public static let statusConnecting = "Connecting"
    public static let statusMicrophonePermission = "Microphone permission"
    public static let statusInputPermission = "Input permission"
    public static let statusPairing = "Pairing with Windows"
    public static let statusDeviceAttention = "Device selection needs attention"
    public static let statusConnected = "Connected"
    public static let statusReady = "Ready"
    /// `local_output_status` (`strings.xml:99`, `MainActivity.kt:1432`); the probe is the only local tool.
    public static let statusProbeRunning = "Tap Play click in Diagnostics. Stop ends the test."
    public static let statusMicrophonePermissionText = "Allow microphone access to continue, or Stop to cancel."
    public static let statusInputPermissionText = "Allow the requested permissions to change input, or Stop to cancel."
    public static let statusStopped = "Stopped."
    /// Idle status text: `"<controls>\nConnect uses these options."`.
    public static func statusIdle(controls: String) -> String { controls + "\nConnect uses these options." }

    // MARK: LAN discovery (`LanDiscovery.kt`)

    public enum Discovery {
        public static let looking = "Looking for Windows hosts on your LAN…"  // :44, :132, :154
        public static let previousStopping = "The previous search is stopping. Tap Find again in a moment."  // :36
        /// `FINISHED` (`LanDiscovery.kt:30`).
        public static let finished = "Search finished. Tap Find again to refresh. QR or paste also work."
        // :75
        public static let noneFound =
            "No Windows hosts found. Check the same LAN and Windows Private-network firewall access. QR or paste still work."
        public static let userStopped = "Search stopped. Tap Find again to refresh."  // :56
        public static let browserStopped = "Discovery stopped. Tap Find to try again."  // :112
        public static let select = "Select Windows below. Its identity will be checked when connecting."  // :149, :179
        // :142
        public static let unresolved = "A Windows address could not be resolved. Try Find again, or use QR/paste."
        public static let startFailed = "LAN discovery could not start. Try again, or use QR/paste."  // :52
        /// iOS `.failed(other)` (ADAPTED of `LanDiscovery.kt:105`).
        public static let couldNotStart = "iOS could not start LAN discovery. Check network access, or use QR/paste."
        /// iOS-only `.waiting(PolicyDenied)` text; sets `localNetworkBlocked`.
        public static let localNetworkPrompt =
            "Allow Local Network access for MicDrop to find Windows. If you declined, turn it on in Settings, or use QR/paste."
        /// `BLOCKED` (ADAPTED of `LanDiscovery.kt:49`).
        public static let blocked =
            "iOS blocked LAN discovery. Turn on Local Network access for MicDrop in Settings, or use QR/paste."
    }

    // MARK: Info.plist usage descriptions ([10]; written into Info.plist by the build owner)

    public enum UsageDescription {
        public static let camera = "MicDrop uses the camera only to scan the Windows pairing QR code."
        public static let localNetwork = "MicDrop finds and connects to your paired Windows computer on this network."
    }
}
