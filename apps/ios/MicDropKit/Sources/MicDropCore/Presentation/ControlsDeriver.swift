import Foundation

/// Pure port of `MainActivity.updateControls` + `renderStatus` (`MainActivity.kt:1149-1347`).
public enum ControlsDeriver {
    /// Phases in which a playback-capable session accepts an output choice (`MainActivity.kt:1189-1191`): the
    /// rule shared with both session controllers (`SessionPhase.acceptsOutputChoice`).
    static func acceptsOutputChoice(_ phase: SessionPhase) -> Bool {
        phase.acceptsOutputChoice
    }

    /// Phases in which the playback session offers Pause (`MainActivity.kt:1272-1273`). iOS adds
    /// routeRecovering, which Android playback never reaches: selected-output recovery (formerly published as
    /// switching) and default-route probing keep Pause, as the lock-screen controls do (`MediaPresentation`).
    static func offersPause(_ phase: SessionPhase) -> Bool {
        switch phase {
        case .playing, .recovering, .routeRecovering, .switching, .interrupted, .pausing: return true
        default: return false
        }
    }

    public static func derive(_ input: ControlsInput) -> ControlsRender {
        var r = ControlsRender()
        let idle = input.idle
        let setupPending = input.setupPending
        let selection = input.selection
        let current = input.current
        let mode = input.mode
        let modePlayback = mode?.hasPlayback == true
        let modeMicrophone = mode?.hasMicrophone == true
        let prefs = input.prefs
        let mic = input.mic
        let session = input.session
        r.idle = idle
        r.setupPending = setupPending

        // MARK: Audio output
        r.outputChecked = mode.map { $0.hasPlayback && current.outputEnabled } ?? prefs.outputEnabled
        let showsPause = modePlayback && current.outputPaused
        r.outputToggleLabel = showsPause ? Strings.enableAudioPaused : Strings.enableAudio
        r.outputStateText =
            !r.outputChecked ? Strings.audioSilenced : (showsPause ? Strings.audioPaused : Strings.audioOn)
        if let mode {
            r.outputToggleEnabled =
                !setupPending && mode.hasPlayback && current.canSetOutput
                && (mode.hasMicrophone ? input.microphoneAvailable : input.playbackAvailable)
        } else {
            r.outputToggleEnabled = !setupPending && idle
        }
        var pausePrefix = ""
        if modePlayback && current.outputEnabled, let pause = current.outputPauseDetail {
            pausePrefix = pause + "\n\n"
        }
        let outputHelpBody: String
        if let mode, !mode.hasPlayback {
            outputHelpBody = Strings.outputUnavailable
        } else if modeMicrophone && selection.kind.isBluetooth {
            outputHelpBody = Strings.headsetOutputHelp
        } else {
            outputHelpBody = Strings.outputHelp
        }
        r.outputHelp = pausePrefix + outputHelpBody
        r.outputDeviceEnabled = !setupPending && (idle || (modePlayback && acceptsOutputChoice(current.phase)))

        // and D042 ("Device missing?", `MainActivity.kt:879-904`): the system picker is how a connected device that the
        // output menu omits becomes the iPhone route. It never changes the selection or the remembered device; it only
        // changes `outputAvailable`, and Connect stays gated until the route resolves the pin.
        // - A Bluetooth headset microphone session owns the live HFP route, so a picker choice would start
        //   headset recovery or end the session: Stop first, whatever the output selection.
        // - A pinned output keeps the picker while no session is retained, whether or not the pin is the route,
        // so reaching an omitted device never requires choosing iPhone media output (which erases the pin). Any
        // retained session (Paused included) or setup needs Stop first, as Android's `stopping =
        // microphoneView.ownsSession || sessionView.retained` (882); `idle` already excludes busy and microphone
        // sessions.
        // - Following the system route (DEFAULT or the temporary speaker) keeps it wherever the output menu is
        // as Control Center does.
        let pinned = !input.selectedOutput.followsSystemRoute
        let headsetRoute = modeMicrophone && selection.kind.isBluetooth
        let noSession = idle && !session.retained
        if headsetRoute {
            r.systemOutputPickerEnabled = false
            r.systemOutputPickerCaption = Strings.routePickerHeadsetCaption
        } else if pinned {
            r.systemOutputPickerEnabled = noSession
            r.systemOutputPickerCaption =
                !noSession
                ? Strings.routePickerPinnedCaption
                : (input.outputAvailable ? Strings.routePickerIdlePinCaption : Strings.routePickerUnavailablePinCaption)
        } else {
            r.systemOutputPickerEnabled = idle || r.outputDeviceEnabled
            r.systemOutputPickerCaption = nil
        }
        // iOS cannot put the picker in the dialog (Android's "Device missing?" button), so the dialog points to
        // the picker row and repeats its Stop caption while that disables it.
        if !r.systemOutputPickerEnabled, let caption = r.systemOutputPickerCaption {
            r.outputDialogMessage = Strings.outputDialogMessage + "\n\n" + caption
        } else {
            r.outputDialogMessage = Strings.outputDialogMessage
        }

        let phoneSpeaker = canUsePhoneSpeaker(session: session, mic: mic)
        let followSystem = canFollowSystemOutput(session: session, mic: mic)
        r.outputActionVisible = phoneSpeaker || followSystem
        r.outputActionLabel = phoneSpeaker ? Strings.usePhoneSpeaker : Strings.followSystemOutput
        if phoneSpeaker {
            r.outputAction = ControlsRender.OutputAction.usePhoneSpeaker
        } else if followSystem {
            r.outputAction = ControlsRender.OutputAction.followSystemOutput
        } else {
            r.outputAction = nil
        }
        r.outputActionEnabled = r.outputDeviceEnabled && (phoneSpeaker || followSystem)

        r.outputNeedsSelection = input.outputNeedsSelection
        let outputTitle =
            input.outputChoices?.first(where: { $0.selection == input.selectedOutput })?.title
            ?? input.selectedOutput.kind.label
        if r.outputNeedsSelection {
            r.outputDeviceLabel = Strings.chooseOutput
        } else {
            let base =
                (modeMicrophone && selection.kind.isBluetooth)
                ? Strings.nextMediaOutput(outputTitle) : Strings.selectedOutput(outputTitle)
            r.outputDeviceLabel = base + (input.outputAvailable ? "" : Strings.unavailableSuffix)
        }
        r.volumeEnabled = (mode?.hasPlayback ?? true) && current.phase != .stopping && input.volumePercent != nil
        if let percent = input.volumePercent {
            r.volumeLabel =
                input.volumeUsesVoiceStream
                ? Strings.voiceVolume(percent: percent) : Strings.mediaVolume(percent: percent)
        } else {
            r.volumeLabel = Strings.playbackVolume
        }

        // MARK: Microphone
        if modeMicrophone {
            r.micChecked = !mic.muted
            r.micToggleEnabled = !setupPending && input.microphoneAvailable && mic.canSetMuted(!mic.muted)
        } else if mode != nil {
            r.micChecked = false
            r.micToggleEnabled = false
        } else {
            r.micChecked = prefs.microphoneEnabled
            r.micToggleEnabled = !setupPending && idle
        }
        if let mode, !mode.hasMicrophone {
            r.micToggleHelp = Strings.microphoneUnavailable
        } else if mic.ownsSession && mic.changing {
            r.micToggleHelp = Strings.microphoneUpdating
        } else if input.inputNeedsSelection {
            r.micToggleHelp = Strings.microphoneReselect
        } else {
            r.micToggleHelp = Strings.microphoneHelp
        }
        r.inputButtonEnabled = !setupPending && (idle || (input.microphoneAvailable && mic.canChooseInput))
        let inputTitle =
            input.inputChoices?.first(where: { $0.selection.sameDevice(selection) })?.title
            ?? selection.kind.label
        if input.inputNeedsSelection {
            r.inputButtonLabel = Strings.microphoneInput
        } else {
            r.inputButtonLabel =
                Strings.selectedMicrophone(inputTitle)
                + ((!mic.ownsSession && !input.inputAvailable) ? Strings.unavailableSuffix : "")
        }
        // iOS MicrophoneSelection carries no leStereo; the persisted preference stands in for `selection.leStereo`,
        // which Android always copies from it.
        let leStereoRequested = selection.kind == .le && prefs.leStereo
        let inputHelpBase: String
        if leStereoRequested {
            inputHelpBase = Strings.inputHelpLEStereo
        } else if selection.kind == .le {
            inputHelpBase = Strings.inputHelpLEMono
        } else if selection.kind == .sco {
            inputHelpBase = Strings.inputHelpSCO
        } else {
            inputHelpBase = Strings.inputHelpDefault
        }
        r.inputHelp = inputHelpBase + (input.inputChoices == nil ? Strings.inputHelpUncheckedSuffix : "")
        // The footer follows `MicrophoneInventory.currentListing`: any retained session other than a Bluetooth
        // microphone session hides HFP inputs, Paused playback included (Android's "Device missing?" stops every
        // retained session, `MainActivity.kt:882`).
        let bluetoothInputsHidden = mic.ownsSession ? !mic.input.kind.isBluetooth : session.retained
        r.inputDialogMessage =
            Strings.microphoneDialogMessage
            + (bluetoothInputsHidden ? "\n" + Strings.microphoneDialogBluetoothFooter : "")
        r.leStereoVisible = selection.kind == .le
        r.leStereoEnabled = r.inputButtonEnabled && selection.kind == .le
        r.leStereoChecked = prefs.leStereo
        r.echoChecked = prefs.echoCancellation
        r.noiseChecked = prefs.noiseReduction
        r.echoEnabled = idle && !selection.kind.isBluetooth && prefs.outputEnabled && input.echoCancellationSupported
        r.noiseEnabled = idle && !selection.kind.isBluetooth && input.noiseReductionSupported
        r.processingHelp =
            selection.kind.isBluetooth ? Strings.microphoneProcessingBluetooth : Strings.microphoneProcessingHelp

        // MARK: Advanced, Diagnostics and connection (`MainActivity.kt:1342-1368`)
        // Play click is enabled and shown only while the local output probe runs (`:1367-1368`).
        r.fastRecoveryChecked = prefs.fastRecovery
        let resume = mic.canResume && input.microphoneAvailable && !setupPending
        r.resumeDuplex = resume
        r.connectEnabled =
            resume
            || (idle
                && (!prefs.microphoneEnabled
                    || PairingInvitation.isPairingLink(input.entered) || input.microphoneAvailable))
        if resume {
            r.connectLabel = Strings.resumeDuplex
        } else if input.pendingConnect || input.pairingIntentPending || input.pendingMicrophone {
            r.connectLabel = Strings.connecting
        } else if input.entered.isEmpty && input.saved.available {
            r.connectLabel = Strings.reconnect
        } else {
            r.connectLabel = Strings.connect
        }
        r.scanEnabled = idle
        r.discoveryEnabled = idle
        r.discoveryButtonLabel = input.discovery.searching ? Strings.stopDiscovery : Strings.findWindows
        r.discoveryStatus = input.discovery.message
        r.discoverySettingsVisible = input.discovery.localNetworkBlocked
        r.discoveryRows = input.discovery.hosts.map { host in
            ControlsRender.DiscoveryRow(
                host: host, label: host.rowLabel(saved: input.savedLink),
                savedCandidate: host.matches(input.savedLink), enabled: idle)
        }
        r.savedMessage = input.saved.message
        r.forgetEnabled = idle && input.saved.present
        r.cancelPairingVisible = input.saved.pairing
        r.cancelPairingEnabled = input.saved.pairing
        r.addressVisible = input.saved.paired
        r.addressEnabled = idle && input.saved.paired
        r.localTestEnabled = idle
        r.fastRecoveryEnabled = idle
        r.invitationEnabled = idle
        r.clickEnabled = input.localProbeRunning
        r.clickVisible = input.localProbeRunning
        r.copyEnabled = input.latestDiagnostics != nil
        r.copyCrashEnabled = !input.crashReportBuilding
        let canPause =
            !mic.ownsSession && !input.pendingConnect && input.playbackAvailable
            && offersPause(session.phase)
        r.pauseVisible = canPause
        r.pauseEnabled = canPause
        r.pauseLabel = session.phase == .interrupted ? Strings.keepPaused : Strings.pause
        r.stopEnabled =
            input.pairingIntentPending || input.saved.pairing || input.pendingMicrophone
            || input.pendingInputChoice || input.local
            || (mic.ownsSession && mic.session.phase != .stopping && input.microphoneAvailable)
            || (session.retained && session.phase != .stopping && input.playbackAvailable)

        // MARK: Section summaries (`MainActivity.kt:1379-1390`)
        // Advanced shows the saved recovery window (`ConnectionTimeout.seconds`), Diagnostics the app version.
        let microphoneState =
            r.micChecked ? Strings.microphoneOn : (modeMicrophone ? Strings.microphoneMuted : Strings.microphoneOff)
        r.connectionSummary = firstLine(input.saved.message)
        r.outputSummary =
            r.outputStateText + " · "
            + ((modeMicrophone && selection.kind.isBluetooth)
                ? Strings.selectedHeadset
                : (r.outputNeedsSelection ? Strings.chooseOutput : input.selectedOutput.kind.label))
        r.microphoneSummary =
            microphoneState + " · "
            + (input.inputNeedsSelection ? Strings.microphoneInput : selection.kind.label)
        r.advancedSummary = Strings.advancedSummary(
            recoverySeconds: ConnectionPreferences.seconds(input.recoveryWindowMs))
        r.diagnosticsSummary = Strings.diagnosticsSummary(versionName: input.versionName)
        r.buildLabel = Strings.buildLabel(input.revision)

        // MARK: Status card
        r.statusTitle = statusTitle(input, current: current, mode: mode)
        let controls = [r.outputStateText, microphoneState].joined(separator: " · ")
        // Periodic diagnostics published as the message carry `" snapshot:"` (`MainActivity.kt:1330`).
        let message: String? = current.messageIsDiagnosticSnapshot ? nil : current.message
        if input.local {
            r.statusText = Strings.statusProbeRunning
        } else if input.pendingMicrophone {
            r.statusText = Strings.statusMicrophonePermissionText
        } else if input.pendingInputChoice {
            r.statusText = Strings.statusInputPermissionText
        } else if input.saved.pairing {
            r.statusText = input.saved.message
        } else if let mode {
            let lines: [String?] = [
                current.destination,
                current.networkStatus,
                controls,
                (mode.hasPlayback && current.outputEnabled) ? current.outputPauseDetail : nil,
                input.idleMessage ?? (current.phase == .playing ? nil : message),
            ]
            r.statusText = lines.compactMap { $0 }.filter { !isBlank($0) }.joined(separator: "\n")
        } else if let idleMessage = input.idleMessage {
            r.statusText = idleMessage
        } else if current.phase == .ended {
            r.statusText = message.map(firstLine) ?? Strings.statusStopped
        } else {
            r.statusText = Strings.statusIdle(controls: controls)
        }
        r.openSettingsVisible = input.settingsLinkSuggested

        // MARK: Diagnostics text
        // Kotlin `listOfNotNull(...).distinct()`: exact (UTF-16) equality, first occurrence kept.
        var details: [String] = []
        for item in [input.idleMessage, current.phase == .ended ? message : nil, input.latestDiagnostics] {
            if let item, !details.contains(where: { $0.utf16.elementsEqual(item.utf16) }) { details.append(item) }
        }
        let joined = details.joined(separator: "\n\n")
        r.diagnosticsText = isBlank(joined) ? Strings.noReport : joined
        return r
    }

    /// `MainActivity.kt:1312-1325`, first match wins.
    static func statusTitle(_ input: ControlsInput, current: SessionView, mode: StreamMode?) -> String {
        if input.local { return Strings.statusLocalTest }
        if input.pendingConnect { return Strings.statusConnecting }
        if input.pendingMicrophone { return Strings.statusMicrophonePermission }
        if input.pendingInputChoice { return Strings.statusInputPermission }
        if input.saved.pairing { return Strings.statusPairing }
        if mode != nil && input.idleMessage != nil { return Strings.statusDeviceAttention }
        if mode != nil && current.phase == .playing { return Strings.statusConnected }
        if mode != nil { return current.phase.label }
        if input.idleMessage != nil { return Strings.connectionNeedsAttention }
        if current.phase == .ended { return current.phase.label }
        return Strings.statusReady
    }

    /// `canUsePhoneSpeaker()` (`MainActivity.kt:868-873`); also the guard of the status-card action.
    public static func canUsePhoneSpeaker(session: SessionView, mic: MicrophoneView) -> Bool {
        if mic.ownsSession {
            return mic.mode.hasPlayback && !mic.input.kind.isBluetooth && mic.session.canUsePhoneSpeaker
        }
        if session.retained { return session.canUsePhoneSpeaker }
        return false
    }

    /// `canFollowAndroidOutput()` (`MainActivity.kt:875-880`).
    public static func canFollowSystemOutput(session: SessionView, mic: MicrophoneView) -> Bool {
        if mic.ownsSession {
            return mic.mode.usesMediaOutput(mic.input.kind) && mic.session.canFollowSystemOutput
        }
        if session.retained { return session.canFollowSystemOutput }
        return false
    }

    /// Kotlin `lineSequence().first()`: text before the first `\r\n`, `\n` or `\r` (whole text if none).
    public static func firstLine(_ text: String) -> String {
        guard let end = text.firstIndex(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else { return text }
        return String(text[..<end])
    }

    /// Kotlin `isBlank()`: empty, or every character is Kotlin `Char.isWhitespace()`
    /// (`Character.isWhitespace || Character.isSpaceChar`): Unicode space, line and paragraph separators
    /// (no-break spaces included) and U+0009…U+000D, U+001C…U+001F. Unlike Swift's `Character.isWhitespace`,
    /// U+0085 is not blank and U+001C…U+001F are.
    static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x09...0x0D, 0x1C...0x1F:
                return true
            default:
                switch scalar.properties.generalCategory {
                case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
                default: return false
                }
            }
        }
    }
}
