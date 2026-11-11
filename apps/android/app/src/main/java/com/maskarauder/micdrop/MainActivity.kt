// SPDX-License-Identifier: MPL-2.0
package com.maskarauder.micdrop

import android.app.AlertDialog
import android.Manifest
import android.content.pm.PackageManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import com.google.zxing.client.android.Intents
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanIntentResult
import com.journeyapps.barcodescanner.ScanOptions

open class MainActivity : ComponentActivity() {
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var audioManager: AudioManager
    private lateinit var focusRequest: AudioFocusRequest
    private lateinit var statusView: TextView
    private lateinit var statusTitle: TextView
    private lateinit var diagnosticsView: TextView
    private lateinit var outputEnabled: CheckBox
    private lateinit var microphoneEnabled: CheckBox
    private lateinit var echoCancellation: CheckBox
    private lateinit var noiseReduction: CheckBox
    private lateinit var processingHelp: TextView
    private lateinit var outputHelp: TextView
    private lateinit var microphoneToggleHelp: TextView
    private lateinit var outputSettingsButton: Button
    private lateinit var outputDeviceButton: Button
    private lateinit var outputActionButton: Button
    private var selectedOutput = rememberedOutput ?: if (MicrophoneService.lastView.ownsSession)
        MicrophoneService.lastView.session.outputSelection else PlaybackService.lastView.outputSelection
    private lateinit var volume: SeekBar
    private lateinit var volumeLabel: TextView
    private lateinit var connectionSection: SettingsSection
    private lateinit var outputSection: SettingsSection
    private lateinit var microphoneSection: SettingsSection
    private lateinit var advancedSection: SettingsSection
    private lateinit var diagnosticsSection: SettingsSection
    private var preferences = AudioPreferences()
    private var renderingControls = false
    private var idleMessage: String? = null
    private lateinit var stopButton: Button
    private lateinit var pauseButton: Button
    private lateinit var connectButton: Button
    private lateinit var scanButton: Button
    private lateinit var scanStatusView: TextView
    private lateinit var discoveryButton: Button
    private lateinit var discoveryStatusView: TextView
    private lateinit var discoveryList: LinearLayout
    private lateinit var lanDiscovery: LanDiscovery
    private var discoveryView = DiscoveryView()
    private var pendingScan: ScanIntentResult? = null
    private var screenResumed = false
    private val scanLauncher = registerForActivityResult(ScanContract()) { result ->
        pendingScan = result
        // Results can arrive during onStart, before the screen is visible and
        // before service binding completes. Scanning only fills the input;
        // Connect remains the explicit network action.
        if (screenResumed) consumeScanResult()
    }
    private lateinit var forgetButton: Button
    private lateinit var cancelPairButton: Button
    private lateinit var addressButton: Button
    private lateinit var savedView: TextView
    private lateinit var savedConnections: SavedConnections
    private var savedState = SavedConnectionView()
    private var receivedSavedView = false
    private val pairingConnect = PairingConnectIntent()
    private val savedObserver: (SavedConnectionView) -> Unit = { state ->
        val newFailure = receivedSavedView && state.pairingFailureId != 0L && state.pairingFailureId != savedState.pairingFailureId
        receivedSavedView = true
        savedState = state
        savedView.text = state.message
        updateControls()
        consumeApprovedPairing()
        if (newFailure) showConnectionNotice()
    }
    private lateinit var invitationInput: EditText
    private lateinit var copyButton: Button
    private lateinit var localButton: Button
    private lateinit var clickButton: Button
    private lateinit var fastRecovery: CheckBox
    private lateinit var keepMicrophoneActive: CheckBox
    private lateinit var allowWindowsSettings: CheckBox
    private lateinit var microphoneInputButton: Button
    private lateinit var microphoneInputHelp: TextView
    private lateinit var leStereoPlayback: CheckBox
    private var microphone: MicrophoneService? = null
    private var microphoneBound = false
    private var microphoneView = MicrophoneService.lastView
    private var selectedMicrophone = rememberedInput ?: microphoneView.input
    private var inputDeviceCallbackRegistered = false
    private val inputDevices = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) { refreshInputControls() }
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) { refreshInputControls() }
        private fun refreshInputControls() { if (screenVisible) updateControls() }
    }
    private var receivedMicrophoneView = false
    private var pendingMicrophoneText: String? = null
    private var pendingMicrophoneMode = StreamMode.MICROPHONE
    private var microphonePermissionReady = false
    private data class PendingInputChoice(val generation: String, val selection: MicrophoneSelection)
    private var pendingInputChoice: PendingInputChoice? = null
    private var inputChoiceReady = false
    private enum class OutputPermissionAction { SELECT, CONNECT, RESUME_DUPLEX }
    private data class PendingOutputPermission(val selection: OutputSelection, val scope: OutputPermissionScope,
        val action: OutputPermissionAction, val text: String? = null, val reconnect: Boolean = false)
    private var pendingOutputPermission: PendingOutputPermission? = null
    private var outputPermissionReady = false
    private val outputPermission = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        val pending = pendingOutputPermission ?: return@registerForActivityResult
        val denial = OutputPermissions.denial(pending.selection.kind, ::permissionGranted)
        if (denial != null) {
            pendingOutputPermission = null; outputPermissionReady = false
            showConnectionFailure(denial); updateControls()
        } else { outputPermissionReady = true; consumeOutputPermission() }
    }
    private val inputChoicePermission = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        val pending = pendingInputChoice ?: return@registerForActivityResult
        val denial = MicrophonePermissions.denial(pending.selection.kind, ::permissionGranted)
            ?: if (microphoneView.mode.playback && !pending.selection.kind.bluetooth)
                OutputPermissions.denial(selectedOutput.kind, ::permissionGranted) else null
        if (denial != null) {
            pendingInputChoice = null; inputChoiceReady = false
            showConnectionFailure(denial); updateControls()
        } else { inputChoiceReady = true; consumeInputChoice() }
    }
    private val microphonePermission = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        if (pendingMicrophoneText == null) return@registerForActivityResult
        // A headset may need only Nearby Devices after microphone consent was
        // granted earlier. The result map contains only permissions requested
        // this time; check the complete current requirements instead.
        val denial = MicrophonePermissions.denial(selectedMicrophone.kind, ::permissionGranted)
        if (denial != null) {
            pendingMicrophoneText = null; microphonePermissionReady = false
            showConnectionFailure(denial)
            updateControls()
        } else { microphonePermissionReady = true; consumeMicrophonePermission() }
    }
    private var localProbe: LocalOutputProbe? = null
    private var localBaseline: OutputSnapshot? = null
    private var latestDiagnostics: String? = null
    private var hasFocus = false
    private var playback: PlaybackService? = null
    private var bound = false
    private var pendingConnect = false
    private var sessionView = PlaybackService.lastView
    private var showingMicrophone = microphoneView.ownsSession
    private var receivedSessionView = false
    private var screenVisible = false
    private var connectionToast: Toast? = null
    private var generation = 0

    private val sessionObserver: (SessionView) -> Unit = { view ->
        val newFailure = receivedSessionView && view.failureId != null && view.failureId != sessionView.failureId
        receivedSessionView = true
        sessionView = view; pendingConnect = false
        if (view.retained && !microphoneView.ownsSession) {
            selectedOutput = view.outputSelection; rememberedOutput = selectedOutput
        }
        if (view.busy && !microphoneView.ownsSession) showingMicrophone = false
        if (localProbe == null && !microphoneView.ownsSession && !showingMicrophone) {
            latestDiagnostics = view.diagnostics ?: latestDiagnostics
            copyButton.isEnabled = latestDiagnostics != null
        }
        updateControls()
        consumeOutputPermission()
        if (newFailure) showConnectionNotice()
    }
    private val microphoneObserver: (MicrophoneView) -> Unit = { view ->
        val wasBusy = microphoneView.ownsSession
        val failure = receivedMicrophoneView && view.session.failureId != null && view.session.failureId != microphoneView.session.failureId
        receivedMicrophoneView = true; microphoneView = view
        if (view.ownsSession) {
            selectedMicrophone = view.input; rememberedInput = view.input
            selectedOutput = view.session.outputSelection; rememberedOutput = selectedOutput
        }
        if ((view.ownsSession || wasBusy || failure) && !sessionView.busy) {
            showingMicrophone = true
            latestDiagnostics = view.session.diagnostics ?: latestDiagnostics
            copyButton.isEnabled = latestDiagnostics != null
        }
        updateControls()
        consumeOutputPermission()
        if (failure) showConnectionNotice()
    }
    private val microphoneConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            microphone = (binder as MicrophoneService.LocalBinder).service
            microphone?.observe(microphoneObserver)
            consumeMicrophonePermission()
            consumeInputChoice()
            consumeOutputPermission()
            consumeApprovedPairing()
        }
        override fun onServiceDisconnected(name: ComponentName) {
            microphone = null
            microphoneObserver(MicrophoneView(SessionView(SessionPhase.ENDED, "Microphone service disconnected. Open MicDrop to start it again.")))
        }
    }
    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            playback = (binder as PlaybackService.LocalBinder).service
            playback?.observe(sessionObserver)
            consumeOutputPermission()
            consumeApprovedPairing()
        }
        override fun onServiceDisconnected(name: ComponentName) {
            playback = null; pendingConnect = false
            sessionObserver(SessionView(SessionPhase.ENDED, "Playback service disconnected. Wait for Windows to end the session, then use Reconnect."))
        }
    }

    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) { stopLocalPlayback() }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        latestDiagnostics = StoredReports.stream(this)
        audioManager = getSystemService(AudioManager::class.java)
        preferences = AppAudioSettings.load(this)
        if (rememberedOutput == null && !selectedOutput.explicit && !sessionView.retained && !microphoneView.ownsSession)
            selectedOutput = AppAudioSettings.output(this)
        if (rememberedInput == null && !microphoneView.ownsSession)
            selectedMicrophone = AppAudioSettings.input(this)
        selectedMicrophone = selectedMicrophone.copy(leStereo = preferences.leStereo)
        savedInstanceState?.getString("microphoneKind")?.let { kind ->
            runCatching { MicrophoneSelection(MicrophoneKind.valueOf(kind),
                savedInstanceState.getInt("microphoneDeviceId"), savedInstanceState.getInt("microphoneDeviceType"),
                savedInstanceState.getBoolean("microphoneLeStereo", true)) }
                .getOrNull()?.let { restored ->
                    // Keep an in-process identity across rotation; the bundle
                    // stores only the selector's existing kind/port/profile.
                    val original = selectedMicrophone
                    val remembered = MicrophoneRouting.refresh(this, original) ?: original
                    if (restored.sameDevice(original) || restored.sameDevice(remembered))
                        selectedMicrophone = restored.copy(headsetEndpoint = remembered.headsetEndpoint)
                }
        }
        savedConnections = SavedConnections.get(applicationContext)
        lanDiscovery = LanDiscovery.get(applicationContext)
        volumeControlStream = AudioManager.STREAM_MUSIC
        focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setOnAudioFocusChangeListener({ change ->
                if (change != AudioManager.AUDIOFOCUS_GAIN) stopLocalPlayback()
            }, handler).build()

        createLayout(savedInstanceState)
        updateControls()
    }

    private fun createLayout(savedState: Bundle?) {
        val spacing = dp(16)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(spacing, spacing, spacing, spacing)
            setOnApplyWindowInsetsListener { view, insets ->
                val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.ime())
                view.setPadding(spacing + bars.left, spacing + bars.top,
                    spacing + bars.right, spacing + bars.bottom)
                insets
            }
        }
        val content = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        content.addView(TextView(this).apply {
            setText(R.string.title); textSize = 28f
            setTextColor(getColor(R.color.accent))
            typeface = android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL)
            isAccessibilityHeading = true
        })
        content.addView(help(R.string.subtitle).apply { setPadding(0, 0, 0, dp(12)) })
        val status = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = getDrawable(R.drawable.settings_card)
            setPadding(dp(14), dp(12), dp(14), dp(12))
        }
        statusTitle = TextView(this).apply {
            textSize = 18f; setTextColor(getColor(R.color.accent))
            isAccessibilityHeading = true
        }
        statusView = TextView(this).apply {
            textSize = 15f; setTextColor(getColor(R.color.text_primary))
        }
        status.addView(statusTitle); status.addView(statusView)
        outputActionButton = button(R.string.use_phone_speaker) { changeOutputFromStatus() }.apply {
            visibility = android.view.View.GONE
        }
        status.addView(outputActionButton)
        content.addView(status, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(8) })
        val actions = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        connectButton = button(R.string.connect) { connectSelected() }.apply {
            backgroundTintList = getColorStateList(R.color.button_primary)
        }
        stopButton = button(R.string.stop) { stopPlayback() }
        actions.addView(connectButton, LinearLayout.LayoutParams(0, -2, 1f).apply { marginEnd = dp(4) })
        actions.addView(stopButton, LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = dp(4) })
        root.addView(actions)
        pauseButton = button(R.string.pause) { playback?.pauseFromActivity() }
        root.addView(pauseButton)

        val sections = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(0, dp(8), 0, 0) }
        connectionSection = SettingsSection(this, getString(R.string.connection_setup),
            savedState?.getBoolean("section.connection") ?: true)
        outputSection = SettingsSection(this, getString(R.string.audio_output),
            savedState?.getBoolean("section.output") ?: false)
        microphoneSection = SettingsSection(this, getString(R.string.microphone),
            savedState?.getBoolean("section.microphone") ?: false)
        advancedSection = SettingsSection(this, getString(R.string.advanced),
            savedState?.getBoolean("section.advanced") ?: false)
        diagnosticsSection = SettingsSection(this, getString(R.string.diagnostics),
            savedState?.getBoolean("section.diagnostics") ?: false)
        for (section in listOf(connectionSection, outputSection, microphoneSection, advancedSection, diagnosticsSection)) sections.addView(section)

        savedView = help()
        discoveryButton = button(R.string.find_windows) {
            if (discoveryView.searching) lanDiscovery.stop() else lanDiscovery.start(::renderDiscovery)
        }
        discoveryStatusView = help()
        discoveryList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        scanButton = button(R.string.scan_pairing) { scanPairing() }
        scanStatusView = help()
        invitationInput = EditText(this).apply {
            setHint(R.string.invitation_hint)
            val states = arrayOf(intArrayOf(android.R.attr.state_enabled), intArrayOf())
            val disabled = getColor(R.color.text_disabled)
            setTextColor(android.content.res.ColorStateList(states,
                intArrayOf(getColor(R.color.text_primary), disabled)))
            setHintTextColor(android.content.res.ColorStateList(states,
                intArrayOf(getColor(R.color.text_secondary), disabled)))
            backgroundTintList = android.content.res.ColorStateList(states,
                intArrayOf(getColor(R.color.accent), disabled))
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE or
                android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            maxLines = 3
            filters = arrayOf(android.text.InputFilter.LengthFilter(4096))
            importantForAutofill = android.view.View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
            isSaveEnabled = false
            addTextChangedListener(object : android.text.TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                    if (::fastRecovery.isInitialized && !renderingControls) updateControls()
                }
                override fun afterTextChanged(s: android.text.Editable?) {}
            })
        }
        cancelPairButton = button(R.string.cancel_pairing) { pairingConnect.cancel(); savedConnections.cancelPairing() }
        addressButton = button(R.string.change_address) { changeAddress() }
        forgetButton = button(R.string.forget_connection) {
            pairingConnect.cancel()
            if (sessionView.phase == SessionPhase.PAUSED) playback?.stopFromActivity()
            PausedPlayback.clear(this@MainActivity)
            savedConnections.forget()
        }
        connectionSection.body.apply {
            addView(savedView); addView(help(R.string.connection_help))
            addView(invitationInput); addView(scanButton); addView(scanStatusView)
            addView(discoveryButton); addView(discoveryStatusView); addView(discoveryList)
            addView(cancelPairButton); addView(addressButton); addView(forgetButton)
        }

        outputEnabled = CheckBox(this).apply {
            setText(R.string.enable_audio); minHeight = dp(48); isSaveEnabled = false
            setOnCheckedChangeListener { _, checked -> if (!renderingControls) changeOutput(checked) }
        }
        outputHelp = help()
        outputDeviceButton = button(R.string.choose_output) { selectOutput() }
        outputSettingsButton = button(R.string.more_bluetooth_devices) { showBluetoothDeviceHelp() }
        volumeLabel = help()
        volume = SeekBar(this).apply {
            minHeight = dp(48); contentDescription = getString(R.string.playback_volume)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(bar: SeekBar?, value: Int, fromUser: Boolean) {
                    if (fromUser) {
                        runCatching { audioManager.setStreamVolume(volumeControlStream, value, 0) }
                        updateVolume()
                    }
                }
                override fun onStartTrackingTouch(bar: SeekBar?) {}
                override fun onStopTrackingTouch(bar: SeekBar?) { updateVolume() }
            })
        }
        outputSection.body.apply {
            addView(outputEnabled); addView(outputDeviceButton); addView(outputHelp)
            addView(volumeLabel); addView(volume); addView(outputSettingsButton)
        }

        microphoneEnabled = CheckBox(this).apply {
            setText(R.string.enable_microphone); minHeight = dp(48); isSaveEnabled = false
            setOnCheckedChangeListener { _, checked -> if (!renderingControls) changeMicrophone(checked) }
        }
        microphoneToggleHelp = help()
        microphoneInputButton = button(R.string.microphone_input) { selectMicrophone() }
        microphoneInputHelp = help()
        echoCancellation = CheckBox(this).apply {
            setText(R.string.microphone_echo); minHeight = dp(48); isSaveEnabled = false
            setOnCheckedChangeListener { _, checked -> if (!renderingControls && isEnabled) {
                preferences = AppAudioSettings.update(this@MainActivity) { it.copy(echoCancellation = checked) }
            } }
        }
        noiseReduction = CheckBox(this).apply {
            setText(R.string.microphone_noise); minHeight = dp(48); isSaveEnabled = false
            setOnCheckedChangeListener { _, checked -> if (!renderingControls && isEnabled) {
                preferences = AppAudioSettings.update(this@MainActivity) { it.copy(noiseReduction = checked) }
            } }
        }
        processingHelp = help(R.string.microphone_processing_help)
        leStereoPlayback = CheckBox(this).apply {
            text = getString(R.string.le_stereo); minHeight = dp(48); isSaveEnabled = false
            setOnCheckedChangeListener { _, checked ->
                if (!renderingControls && microphoneInputButton.isEnabled && selectedMicrophone.kind == MicrophoneKind.LE) {
                    chooseMicrophone(selectedMicrophone.copy(leStereo = checked))
                }
            }
        }
        microphoneSection.body.apply {
            addView(microphoneEnabled); addView(microphoneToggleHelp); addView(microphoneInputButton)
            addView(microphoneInputHelp); addView(leStereoPlayback)
            addView(echoCancellation); addView(noiseReduction); addView(processingHelp)
        }

        fastRecovery = CheckBox(this).apply {
            setText(R.string.fast_recovery); minHeight = dp(48); isSaveEnabled = false
            setOnCheckedChangeListener { _, checked -> if (!renderingControls) {
                preferences = AppAudioSettings.update(this@MainActivity) { it.copy(fastRecovery = checked) }
            } }
        }
        keepMicrophoneActive = CheckBox(this).apply {
            setText(R.string.keep_microphone_active); minHeight = dp(48); isSaveEnabled = false
            setOnCheckedChangeListener { _, checked -> if (!renderingControls) {
                preferences = AppAudioSettings.update(this@MainActivity) { it.copy(keepMicrophoneActive = checked) }
            } }
        }
        allowWindowsSettings = CheckBox(this).apply {
            setText(R.string.allow_windows_settings); minHeight = dp(48); isSaveEnabled = false
            setOnCheckedChangeListener { _, checked -> if (!renderingControls) {
                AppPhoneControlSettings.setEnabled(this@MainActivity, checked)
            } }
        }
        copyButton = button(R.string.copy_diagnostics) {
            (if (localBaseline != null) latestDiagnostics else StoredReports.stream(this) ?: latestDiagnostics)?.let { report ->
                getSystemService(android.content.ClipboardManager::class.java)
                    .setPrimaryClip(android.content.ClipData.newPlainText("MicDrop diagnostics", report))
                Toast.makeText(this@MainActivity, R.string.diagnostics_copied, Toast.LENGTH_SHORT).show()
            }
        }
        val crashButton = button(R.string.copy_crash_diagnostics) { }
        crashButton.setOnClickListener {
            crashButton.isEnabled = false
            val app = applicationContext
            Thread({
                val report = runCatching { CrashDiagnostics.latest(app) }.getOrDefault("Crash information unavailable.")
                handler.post {
                    if (!isDestroyed) {
                        crashButton.isEnabled = true
                        getSystemService(android.content.ClipboardManager::class.java)
                            .setPrimaryClip(android.content.ClipData.newPlainText("MicDrop crash diagnostics", report))
                        Toast.makeText(this, R.string.crash_diagnostics_copied, Toast.LENGTH_LONG).show()
                    }
                }
            }, "MicDrop-crash-report").start()
        }
        localButton = button(R.string.local_output_test) { startLocalOutput() }
        clickButton = button(R.string.play_click) { localProbe?.playClick() }
        diagnosticsView = TextView(this).apply {
            textSize = 12f; setTextColor(getColor(R.color.text_secondary))
            typeface = android.graphics.Typeface.MONOSPACE
            setTextIsSelectable(true)
        }
        advancedSection.body.apply {
            addView(help(R.string.advanced_help))
            addView(allowWindowsSettings)
            addView(help(R.string.windows_settings_help))
            for (group in ConnectionSettingsGroup.entries) {
                addView(Button(this@MainActivity).apply {
                    text = group.label; isAllCaps = false; minHeight = dp(48)
                    setOnClickListener { ConnectionSettingsDialog.show(this@MainActivity, group) { updateControls() } }
                })
            }
            addView(keepMicrophoneActive); addView(help(R.string.keep_microphone_active_help))
            addView(fastRecovery)
        }
        diagnosticsSection.body.apply {
            addView(help(R.string.diagnostics_help))
            addView(help(R.string.build_label, BuildConfig.REVISION))
            addView(copyButton); addView(crashButton)
            addView(localButton); addView(clickButton)
            addView(diagnosticsView)
            addView(button(R.string.notices) { showNotices() })
        }
        content.addView(sections)
        root.addView(ScrollView(this).apply {
            isFillViewport = true; addView(content)
        }, 0, LinearLayout.LayoutParams(-1, 0, 1f))
        setContentView(root)
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun button(label: Int, action: () -> Unit) = Button(this).apply {
        setText(label); isAllCaps = false; minHeight = dp(48); minWidth = 0; maxLines = 2
        setOnClickListener { action() }
    }
    private fun help(label: Int? = null, vararg args: Any): TextView = TextView(this).apply {
        textSize = 14f; setTextColor(getColor(R.color.text_secondary))
        setPadding(0, dp(4), 0, dp(8))
        if (label != null) text = getString(label, *args)
    }
    private fun showNotices() {
        val content = TextView(this).apply {
            text = listOf("NOTICE", "LICENSE", "qr-notices.txt", "remote-notices.txt", "webrtc-notice.txt").joinToString("\n\n") { file ->
                assets.open(file).bufferedReader().use { it.readText() }
            }
            setPadding(dp(16), dp(16), dp(16), dp(16))
        }
        AlertDialog.Builder(this).setTitle(R.string.notices)
            .setView(ScrollView(this).apply { addView(content) })
            .setPositiveButton(android.R.string.ok, null).show()
    }

    override fun onStart() {
        super.onStart()
        screenVisible = true
        // Initial snapshots retain the reason without replaying an old toast
        // after rotation or returning from the background.
        receivedSavedView = false; receivedSessionView = false; receivedMicrophoneView = false
        savedConnections.observe(savedObserver)
        bound = bindService(Intent(this, PlaybackService::class.java).setAction(PlaybackService.ACTION_LOCAL_BIND), serviceConnection, BIND_AUTO_CREATE)
        microphoneBound = bindService(Intent(this, MicrophoneService::class.java), microphoneConnection, BIND_AUTO_CREATE)
        inputDeviceCallbackRegistered = runCatching {
            audioManager.registerAudioDeviceCallback(inputDevices, handler); true
        }.getOrDefault(false)
    }

    override fun onStop() {
        screenVisible = false
        // Approval can still finish saving in the background. Starting a new
        // capture/service must come from a fresh visible action after returning.
        pairingConnect.cancel()
        if (inputDeviceCallbackRegistered) runCatching { audioManager.unregisterAudioDeviceCallback(inputDevices) }
        inputDeviceCallbackRegistered = false
        clearDiscovery()
        connectionToast?.cancel(); connectionToast = null
        savedConnections.removeObserver(savedObserver)
        playback?.removeObserver(sessionObserver)
        playback = null
        if (bound) { unbindService(serviceConnection); bound = false }
        microphone?.removeObserver(microphoneObserver); microphone = null
        if (microphoneBound) { unbindService(microphoneConnection); microphoneBound = false }
        pendingMicrophoneText = null; microphonePermissionReady = false
        pendingInputChoice = null; inputChoiceReady = false
        pendingOutputPermission = null; outputPermissionReady = false
        super.onStop()
    }

    override fun onResume() {
        super.onResume()
        updateControls()
        val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(noisyReceiver, filter, RECEIVER_NOT_EXPORTED)
        else registerReceiver(noisyReceiver, filter)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean("section.connection", connectionSection.expanded)
        outState.putBoolean("section.output", outputSection.expanded)
        outState.putBoolean("section.microphone", microphoneSection.expanded)
        outState.putBoolean("section.advanced", advancedSection.expanded)
        outState.putBoolean("section.diagnostics", diagnosticsSection.expanded)
        val selection = if (microphoneView.ownsSession) microphoneView.input else selectedMicrophone
        outState.putString("microphoneKind", selection.kind.name)
        outState.putInt("microphoneDeviceId", selection.deviceId)
        outState.putInt("microphoneDeviceType", selection.deviceType)
        outState.putBoolean("microphoneLeStereo", selection.leStereo)
        super.onSaveInstanceState(outState)
    }

    override fun onPause() {
        screenResumed = false
        // Local measurement tools are foreground-only. A service-owned stream
        // survives Home, screen lock, rotation, and activity recreation.
        stopLocalPlayback()
        unregisterReceiver(noisyReceiver)
        super.onPause()
    }

    override fun onPostResume() {
        super.onPostResume()
        screenResumed = true
        consumeInputChoice()
        consumeOutputPermission()
        consumeScanResult()
        consumeMicrophonePermission()
        consumeApprovedPairing()
    }

    private fun scanPairing() {
        if (!scanButton.isEnabled) return
        clearDiscovery()
        scanStatusView.text = ""
        if (!packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_CAMERA_ANY)) {
            scanStatusView.setText(R.string.scan_camera_unavailable)
            showConnectionNotice(R.string.scan_camera_unavailable)
            return
        }
        // CaptureActivity requests CAMERA only when opened, pauses its camera
        // on background/rotation, and never saves a frame with this option off.
        val options = ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE)
            .setPrompt(getString(R.string.scan_prompt)).setOrientationLocked(false)
            .setBeepEnabled(false).setBarcodeImageEnabled(false)
            .addExtra(Intents.Scan.SCAN_TYPE, Intents.Scan.MIXED_SCAN)
            .addExtra(Intents.Scan.SHOW_MISSING_CAMERA_PERMISSION_DIALOG, false)
        try { scanLauncher.launch(options) }
        catch (_: RuntimeException) {
            scanStatusView.setText(R.string.scan_camera_unavailable)
            showConnectionNotice(R.string.scan_camera_unavailable)
        }
    }

    private fun consumeScanResult() {
        val result = pendingScan ?: return
        pendingScan = null
        if (result.originalIntent?.getBooleanExtra(Intents.Scan.MISSING_CAMERA_PERMISSION, false) == true) {
            scanStatusView.setText(R.string.scan_camera_denied)
            return
        }
        val contents = result.contents ?: return // Back/cancel is not a connection failure.
        invitationInput.text.clear() // A rejected scan must not leave an older link ready to connect.
        val text = contents.trim()
        try {
            val invitation = PairingInvitation.parse(text)
            if (invitation.expired()) {
                scanStatusView.setText(R.string.scan_expired)
                showConnectionNotice(R.string.connection_link_expired)
                return
            }
            // Only enrollment QR codes are accepted. Never open arbitrary URLs,
            // import saved credentials, start audio, or replace a pairing here.
            invitationInput.setText(text)
            scanStatusView.text = getString(R.string.scan_ready, invitation.host, invitation.port)
            showConnectionNotice(R.string.scan_complete)
        } catch (_: Exception) {
            scanStatusView.setText(R.string.scan_invalid)
            showConnectionNotice(R.string.scan_invalid)
        }
    }

    // Only the debug source-set's permission-protected activity calls this.
    // The exported launcher never reads automation extras. Use the same visible
    // controls, permission prompts and single-session services as a manual test.
    protected fun debugCommand(command: String, mode: String?, enabled: Boolean?, invitation: String?): String? {
        check(BuildConfig.DEBUG)
        if (command == "launch") return "ok"
        if (!screenResumed || playback == null || microphone == null ||
            (savedState.working && !savedState.pairing)) return null
        updateControls()
        when (command) {
            "connect", "pair" -> {
                if (sessionView.retained || microphoneView.ownsSession || !connectButton.isEnabled)
                    return "busy_stop_first"
                val text = if (command == "pair") {
                    if (invitation == null || !PairingInvitation.isPairingLink(invitation)) return "invalid_invitation"
                    try { PairingInvitation.parse(invitation) } catch (_: Exception) { return "invalid_invitation" }
                    invitation
                } else savedConnections.connection() ?: return "no_saved_connection"
                val options = when (mode) {
                    null -> preferences
                    "playback" -> preferences.copy(outputEnabled = true, microphoneEnabled = false)
                    "microphone" -> preferences.copy(outputEnabled = false, microphoneEnabled = true)
                    "duplex" -> preferences.copy(outputEnabled = true, microphoneEnabled = true)
                    else -> return "invalid_mode"
                }
                preferences = AppAudioSettings.update(this) { options }
                connect(text, command == "connect")
                return "requested_check_status"
            }
            "stop" -> stopPlayback()
            "microphone" -> {
                if (enabled == null || !microphoneView.ownsSession || !microphoneEnabled.isEnabled)
                    return "control_unavailable"
                changeMicrophone(enabled)
            }
            "output" -> {
                if (enabled == null || !outputEnabled.isEnabled) return "control_unavailable"
                changeOutput(enabled)
            }
            "status" -> {
                val current = if (microphoneView.ownsSession) microphoneView.session else sessionView
                return "phase=${current.phase.name.lowercase()} saved=${savedState.available} build=${BuildConfig.REVISION}"
            }
            "report" -> {
                val report = StoredReports.stream(this) ?: return "no_report"
                java.io.File(noBackupFilesDir, "adb-session-report.txt").writeText(report, Charsets.UTF_8)
                return "report_saved"
            }
            else -> return "invalid_command"
        }
        return "ok"
    }

    private fun connectSelected() {
        if (!screenResumed || !connectButton.isEnabled) return
        if (microphoneView.canResume) {
            if (microphoneView.mode.playback && !microphoneView.input.kind.bluetooth &&
                requestOutputConsent(PendingOutputPermission(selectedOutput, outputPermissionScope(), OutputPermissionAction.RESUME_DUPLEX))) return
            microphone?.resumeFromActivity(); return
        }
        val entered = invitationInput.text.toString().trim()
        if (entered.isNotEmpty()) { connect(entered); return }
        val saved = savedConnections.connection()
        if (saved != null) connect(saved, true)
        else {
            connectionSection.expand(true)
            showConnectionFailure(savedState.message)
            invitationInput.requestFocus()
        }
    }

    private fun connect(text: String, reconnect: Boolean = false) {
        pairingConnect.cancel()
        if (playback == null || sessionView.busy || microphoneView.ownsSession || pendingMicrophoneText != null ||
            pendingOutputPermission != null || pendingConnect || savedState.working) return
        clearDiscovery()
        scanStatusView.text = ""
        if (PairingInvitation.isPairingLink(text)) { pairWithWindows(text); return }
        try {
            if (LanInvitation.parse(text).expired()) {
                showConnectionFailure("That connection link expired. Restart Windows and paste its new link.", R.string.connection_link_expired)
                return
            }
        }
        catch (_: Exception) { showConnectionFailure(getString(R.string.invalid_invitation)); return }
        preferences = AppAudioSettings.load(this)
        if (preferences.connectionMode.playback && (!preferences.microphoneEnabled || !selectedMicrophone.kind.bluetooth) &&
            requestOutputConsent(PendingOutputPermission(selectedOutput, outputPermissionScope(), OutputPermissionAction.CONNECT, text, reconnect))) return
        if (preferences.connectionMode.playback &&
            (!preferences.microphoneEnabled || !selectedMicrophone.kind.bluetooth) && !checkOutputChoice()) return
        if (preferences.microphoneEnabled) {
            requestMicrophone(text, preferences.connectionMode)
            return
        }
        idleMessage = null
        showingMicrophone = false
        pendingConnect = true
        updateControls()
        try {
            invitationInput.text.clear()
            latestDiagnostics = null; copyButton.isEnabled = false
            playback?.connectFromActivity(text, preferences.fastRecovery, localBaseline, reconnect, preferences.outputEnabled, selectedOutput)
        } catch (_: RuntimeException) {
            pendingConnect = false; updateControls()
            showConnectionFailure("Android could not start playback. Keep MicDrop open and try Connect again.")
        }
    }

    private fun selectMicrophone() {
        if (!screenResumed || !microphoneInputButton.isEnabled) return
        try {
            val choices = MicrophoneRouting.choices(this)
            AlertDialog.Builder(this).setTitle("Microphone input")
                .setItems(choices.map { it.title }.toTypedArray()) { _, index ->
                    if (!screenResumed || !microphoneInputButton.isEnabled) return@setItems
                    chooseMicrophone(choices[index].selection.copy(leStereo = preferences.leStereo))
                }.setNeutralButton(R.string.more_bluetooth_devices) { _, _ -> showBluetoothDeviceHelp() }
                .setNegativeButton("Cancel", null).show()
        } catch (_: RuntimeException) {
            showConnectionFailure("Android could not list microphone inputs. Check your headset connection and try again.")
        }
    }

    private fun chooseMicrophone(selection: MicrophoneSelection) {
        if (!screenResumed || !microphoneInputButton.isEnabled) return
        if (!microphoneView.ownsSession) {
            selectedMicrophone = selection; rememberedInput = selection
            preferences = AppAudioSettings.selectInput(this, selection)
            idleMessage = null; updateControls()
            return
        }
        val token = microphone?.inputActionToken() ?: return
        pendingInputChoice = PendingInputChoice(token, selection)
        idleMessage = null
        val missing = MicrophonePermissions.missing(selection.kind, ::permissionGranted) +
            (if (microphoneView.mode.playback && !selection.kind.bluetooth)
                OutputPermissions.missing(selectedOutput.kind, ::permissionGranted) else emptyList())
        if (missing.isEmpty()) { inputChoiceReady = true; consumeInputChoice() }
        else { updateControls(); inputChoicePermission.launch(missing.toTypedArray()) }
    }

    private fun consumeInputChoice() {
        val pending = pendingInputChoice ?: return
        if (!inputChoiceReady || !screenResumed || !screenVisible || microphone == null) return
        pendingInputChoice = null; inputChoiceReady = false
        if (microphone?.inputActionToken() != pending.generation) { updateControls(); return }
        MicrophonePermissions.denial(pending.selection.kind, ::permissionGranted)?.let {
            showConnectionFailure(it); updateControls(); return
        }
        val selected = MicrophoneRouting.refresh(this, pending.selection, revealAddress = true)
            ?: run { showConnectionFailure(MicrophoneRouteProblem.UNAVAILABLE.detail); updateControls(); return }
        if (microphoneView.mode.playback && !selected.kind.bluetooth && !checkOutputChoice()) { updateControls(); return }
        if (microphone?.switchInputFromActivity(selected, pending.generation) != true)
            showConnectionFailure(getString(R.string.input_change_unavailable))
        updateControls()
    }

    private fun checkOutputChoice(): Boolean {
        OutputPermissions.denial(selectedOutput.kind, ::permissionGranted)?.let { showConnectionFailure(it); return false }
        val refreshed = OutputDevices.refresh(this, selectedOutput, revealAddress = true)
        if (!preferences.needsOutputSelection(selectedOutput) && refreshed != null) {
            selectedOutput = refreshed; rememberedOutput = refreshed
            return true
        }
        outputSection.expand(true)
        showConnectionFailure(getString(R.string.output_reselect))
        return false
    }

    private fun selectOutput() {
        if (!screenResumed || !outputDeviceButton.isEnabled) return
        try {
            val choices = OutputDevices.choices(this)
            AlertDialog.Builder(this).setTitle(R.string.choose_output)
                .setItems(choices.map { it.title }.toTypedArray()) { _, index ->
                    if (!screenResumed || !outputDeviceButton.isEnabled) return@setItems
                    val selected = choices[index].selection
                    if (!requestOutputConsent(PendingOutputPermission(selected, outputPermissionScope(), OutputPermissionAction.SELECT)))
                        applyOutputChoice(selected)
                }.setNeutralButton(R.string.more_bluetooth_devices) { _, _ -> showBluetoothDeviceHelp() }
                .setNegativeButton(android.R.string.cancel, null).show()
        } catch (_: RuntimeException) {
            showConnectionFailure(getString(R.string.output_change_unavailable))
        }
    }

    private fun outputPermissionScope(): OutputPermissionScope = when {
        microphoneView.ownsSession -> OutputPermissionScope(microphoneView.mode, microphone?.outputActionToken())
        sessionView.retained -> OutputPermissionScope(StreamMode.PLAYBACK, playback?.outputActionToken())
        else -> OutputPermissionScope(null, null)
    }
    private fun showBluetoothDeviceHelp() {
        if (!screenResumed || !screenVisible) return
        val scope = outputPermissionScope()
        val stopping = microphoneView.ownsSession || sessionView.retained
        // A system picker cannot identify an absent audio port for our pinned
        // selection. Stop first; never discard the pin or infer a new one from
        // a route name. Returning from Android grants no reconnect/mic consent.
        fun open(action: () -> Unit) {
            if (!screenResumed || !screenVisible) return
            if (!scope.matches(outputPermissionScope())) {
                showConnectionFailure(getString(R.string.device_picker_state_changed)); return
            }
            stopPlayback()
            action()
        }
        AlertDialog.Builder(this).setTitle(R.string.more_bluetooth_devices)
            .setMessage(getString(R.string.bluetooth_device_help) +
                if (stopping) "\n\n" + getString(R.string.device_picker_stops_session) else "")
            .setPositiveButton(if (stopping) R.string.stop_and_open_output_picker else R.string.android_output_picker) { _, _ ->
                open { openAndroidOutputPicker() }
            }
            .setNeutralButton(if (stopping) R.string.stop_and_open_bluetooth_settings else R.string.bluetooth_settings) { _, _ ->
                open { openBluetoothSettings() }
            }
            .setNegativeButton(android.R.string.cancel, null).show()
    }
    private fun openAndroidOutputPicker() {
        if (!screenResumed || !screenVisible) return
        if (Build.VERSION.SDK_INT >= 34 && runCatching {
                android.media.MediaRouter2.getInstance(this).showSystemOutputSwitcher()
            }.getOrDefault(false)) return
        // Older Android versions and OEMs may not provide the system dialog.
        openBluetoothSettings()
    }
    private fun openBluetoothSettings() {
        if (!screenResumed || !screenVisible) return
        try { startActivity(Intent(android.provider.Settings.ACTION_BLUETOOTH_SETTINGS)) }
        catch (_: RuntimeException) { showConnectionFailure(getString(R.string.bluetooth_settings_unavailable)) }
    }
    private fun requestOutputConsent(pending: PendingOutputPermission): Boolean {
        val missing = OutputPermissions.missing(pending.selection.kind, ::permissionGranted)
        if (missing.isEmpty()) return false
        pendingOutputPermission = pending; outputPermissionReady = false; idleMessage = null
        outputSection.expand(true); updateControls()
        outputPermission.launch(missing.toTypedArray())
        return true
    }
    private fun consumeOutputPermission() {
        val pending = pendingOutputPermission ?: return
        if (!outputPermissionReady || !screenResumed || !screenVisible || playback == null ||
            (microphoneView.ownsSession && microphone == null)) return
        if (!pending.scope.matches(outputPermissionScope())) {
            pendingOutputPermission = null; outputPermissionReady = false; updateControls(); return
        }
        // A focus interruption can still be disposing its old peer. Wait for
        // the retained pause instead of applying a selection during teardown.
        val current = if (microphoneView.ownsSession) microphoneView.session else sessionView
        if (current.phase == SessionPhase.PAUSING) return
        pendingOutputPermission = null; outputPermissionReady = false
        OutputPermissions.denial(pending.selection.kind, ::permissionGranted)?.let {
            showConnectionFailure(it); updateControls(); return
        }
        val selected = OutputDevices.refresh(this, pending.selection, revealAddress = true)
            ?: run { showConnectionFailure(getString(R.string.output_reselect)); updateControls(); return }
        when (pending.action) {
            OutputPermissionAction.SELECT -> applyOutputChoice(selected)
            OutputPermissionAction.CONNECT -> {
                selectedOutput = selected; rememberedOutput = selected
                pending.text?.let { connect(it, pending.reconnect) }
            }
            OutputPermissionAction.RESUME_DUPLEX -> {
                if (microphoneView.canResume && microphone?.setOutputSelection(selected) == true) {
                    selectedOutput = selected; rememberedOutput = selected
                    microphone?.resumeFromActivity()
                }
            }
        }
        updateControls()
    }
    private fun applyOutputChoice(choice: OutputSelection) {
        val selected = OutputDevices.refresh(this, choice, revealAddress = true)
            ?: run { showConnectionFailure(getString(R.string.output_reselect)); updateControls(); return }
        val accepted = when {
            microphoneView.ownsSession -> microphone?.setOutputSelection(selected) == true
            sessionView.retained -> playback?.setOutputSelection(selected) == true
            else -> { preferences = AppAudioSettings.selectOutput(this, selected); true }
        }
        if (accepted) { selectedOutput = selected; rememberedOutput = selected; idleMessage = null }
        else showConnectionFailure(getString(R.string.output_change_unavailable))
        updateControls()
    }

    private fun canUsePhoneSpeaker(): Boolean = when {
        microphoneView.ownsSession -> microphoneView.mode.playback && !microphoneView.input.kind.bluetooth &&
            microphoneView.session.canUsePhoneSpeaker
        sessionView.retained -> sessionView.canUsePhoneSpeaker
        else -> false
    }

    private fun canFollowAndroidOutput(): Boolean = when {
        microphoneView.ownsSession -> microphoneView.mode.usesMediaOutput(microphoneView.input.kind) &&
            microphoneView.session.canFollowAndroidOutput
        sessionView.retained -> sessionView.canFollowAndroidOutput
        else -> false
    }

    private fun changeOutputFromStatus() {
        if (!screenResumed || !screenVisible || !outputActionButton.isEnabled || !outputDeviceButton.isEnabled) {
            updateControls(); return
        }
        // Use the existing route-selection path and current session. It verifies
        // the new route before releasing audio, without starting or unmuting capture.
        when {
            canUsePhoneSpeaker() -> applyOutputChoice(OutputSelection.fallbackSpeaker())
            canFollowAndroidOutput() -> applyOutputChoice(OutputSelection())
            else -> updateControls()
        }
    }

    private fun requestMicrophone(text: String, mode: StreamMode) {
        if (!screenResumed || microphone == null) return
        if (LanInvitation.parse(text).version != 3) {
            connectionSection.expand(true)
            showConnectionFailure("Pair with Windows before using microphone return."); return
        }
        if (preferences.needsInputSelection(selectedMicrophone)) {
            microphoneSection.expand(true)
            showConnectionFailure(getString(R.string.microphone_reselect)); return
        }
        idleMessage = null
        showingMicrophone = true
        pendingMicrophoneText = text
        pendingMicrophoneMode = mode
        val permissions = MicrophonePermissions.missing(selectedMicrophone.kind, ::permissionGranted).toMutableList()
        if (permissions.isEmpty()) {
            microphonePermissionReady = true; consumeMicrophonePermission()
        } else {
            updateControls()
            if (Build.VERSION.SDK_INT >= 33 && !permissionGranted(Manifest.permission.POST_NOTIFICATIONS))
                permissions.add(Manifest.permission.POST_NOTIFICATIONS)
            microphonePermission.launch(permissions.toTypedArray())
        }
    }

    private fun permissionGranted(permission: String): Boolean =
        checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun consumeMicrophonePermission() {
        val text = pendingMicrophoneText ?: return
        if (!microphonePermissionReady || !screenResumed || !screenVisible || microphone == null) return
        val mode = pendingMicrophoneMode
        pendingMicrophoneText = null; microphonePermissionReady = false
        if (sessionView.busy || microphoneView.ownsSession || pendingConnect || savedState.working ||
            !preferences.microphoneEnabled) {
            updateControls(); return
        }
        MicrophonePermissions.denial(selectedMicrophone.kind, ::permissionGranted)?.let {
            showConnectionFailure(it); updateControls(); return
        }
        if (mode.playback && !selectedMicrophone.kind.bluetooth && !checkOutputChoice()) { updateControls(); return }
        // Re-enumerate after permission grant while this explicit action is
        // still foreground. The selected exact port can now reveal its address;
        // a different port cannot initialize an addressless identity.
        selectedMicrophone = MicrophoneRouting.refresh(this, selectedMicrophone, revealAddress = true)
            ?: run { showConnectionFailure(MicrophoneRouteProblem.UNAVAILABLE.detail); updateControls(); return }
        try {
            clearDiscovery(); stopLocalPlayback()
            if (sessionView.retained) playback?.stopFromActivity()
            PausedPlayback.clear(this) // Media Play must never recreate this microphone session.
            latestDiagnostics = null; copyButton.isEnabled = false
            rememberedInput = selectedMicrophone
            microphone?.connectFromActivity(text, mode, selectedMicrophone, preferences.outputEnabled, preferences.fastRecovery, selectedOutput)
        } catch (error: MicrophoneRouteException) {
            showConnectionFailure(error.problem.detail)
        } catch (_: Exception) {
            showConnectionFailure("Microphone return could not start. Keep MicDrop open and check microphone permission.")
        }
        updateControls()
    }

    private fun pairWithWindows(text: String) {
        if (playback == null || sessionView.busy || microphoneView.ownsSession || pendingMicrophoneText != null ||
            pendingOutputPermission != null || pendingConnect || savedState.working) return
        try {
            if (PairingInvitation.parse(text).expired()) {
                showConnectionFailure(getString(R.string.pairing_invitation_expired), R.string.connection_link_expired)
                return
            }
            if (sessionView.phase == SessionPhase.PAUSED) playback?.stopFromActivity()
            PausedPlayback.clear(this)
            val label = Build.MODEL.replace(Regex("[^A-Za-z0-9 ._()-]"), "_").take(64).ifBlank { "Android" }
            pairingConnect.begin(savedConnections.pair(text, label))
            invitationInput.text.clear()
            updateControls()
        } catch (_: Exception) {
            showConnectionFailure("Paste the pairing invitation from the paired Windows host.")
        }
    }

    private fun consumeApprovedPairing() {
        if (!pairingConnect.pending) return
        val options = AppAudioSettings.load(this)
        val ready = screenResumed && playback != null && (!options.microphoneEnabled || microphone != null) &&
            !sessionView.busy && !microphoneView.ownsSession && !pendingConnect &&
            pendingMicrophoneText == null && pendingOutputPermission == null && pendingInputChoice == null
        if (!pairingConnect.take(savedState.pairingSuccessId, savedState.working, savedState.available, ready)) {
            if (!pairingConnect.pending) updateControls()
            return
        }
        val text = savedConnections.connection() ?: return
        idleMessage = null
        // Read the current toggles/sources, then use the same permission and
        // service path as a manual Connect. Pairing never grants mic consent.
        connect(text, true)
    }

    private fun showConnectionFailure(detail: String, notice: Int = R.string.connection_failed) {
        idleMessage = detail
        statusView.text = detail
        statusTitle.text = "Connection needs attention"
        showConnectionNotice(notice)
    }

    private fun showConnectionNotice(message: Int = R.string.connection_failed) {
        if (!screenVisible) return
        connectionToast?.cancel()
        connectionToast = Toast.makeText(this, message, Toast.LENGTH_SHORT).also { it.show() }
    }

    private fun renderDiscovery(view: DiscoveryView) {
        discoveryView = view
        discoveryStatusView.text = view.message
        discoveryButton.setText(if (view.searching) R.string.stop_discovery else R.string.find_windows)
        discoveryList.removeAllViews()
        val saved = savedConnections.connection()?.let { LanInvitation.parse(it) }
        for (host in view.hosts) {
            discoveryList.addView(Button(this).apply {
                text = if (host.matches(saved)) getString(R.string.discovered_saved, host.host, host.port)
                    else getString(R.string.discovered_host, host.keyHint.take(12), host.host, host.port)
                setOnClickListener { selectDiscoveredHost(host) }
            })
        }
        updateControls()
    }

    private fun clearDiscovery() {
        lanDiscovery.detach()
        renderDiscovery(DiscoveryView())
    }

    private fun selectDiscoveredHost(host: DiscoveredHost) {
        if (sessionView.busy || microphoneView.ownsSession || pendingMicrophoneText != null ||
            pendingOutputPermission != null || pendingConnect || savedState.working || playback == null) return
        if (host !in discoveryView.hosts) return
        val saved = savedConnections.connection()?.let { LanInvitation.parse(it) }
        if (host.matches(saved)) {
            AlertDialog.Builder(this).setTitle(R.string.discovered_connect_title)
                .setMessage(getString(R.string.discovered_connect_message, host.host, host.port))
                .setNegativeButton(android.R.string.cancel, null)
                .setPositiveButton(R.string.connect) { _, _ ->
                    if (sessionView.busy || microphoneView.ownsSession || pendingMicrophoneText != null ||
                        pendingOutputPermission != null || pendingConnect || savedState.working || playback == null) return@setPositiveButton
                    // Re-read the saved pairing after the dialog. An advertisement
                    // can suggest an endpoint, but never the key used for TLS.
                    val current = savedConnections.connection()?.let { LanInvitation.parse(it) }
                    if (current == null || !host.matches(current)) {
                        showConnectionFailure(getString(R.string.discovery_pair_first)); return@setPositiveButton
                    }
                    connect(host.connectionFor(current).pairedRecord(), true)
                    // SavedConnections.remember runs only after authenticated Playing.
                }.show()
        } else {
            AlertDialog.Builder(this).setTitle(R.string.discovery_pair_title)
                .setMessage(R.string.discovery_pair_first)
                .setNegativeButton(android.R.string.cancel, null)
                .setNeutralButton(R.string.discovery_paste) { _, _ ->
                    clearDiscovery(); invitationInput.requestFocus()
                }
                .setPositiveButton(R.string.scan_pairing) { _, _ -> scanPairing() }.show()
        }
    }

    private fun changeAddress() {
        val text = savedConnections.connection() ?: return
        val connection = LanInvitation.parse(text)
        if (connection.version != 3) return
        val fields = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val host = EditText(this).apply { setText(connection.host); hint = "Windows private IPv4 address"; isSingleLine = true }
        val port = EditText(this).apply {
            setText(connection.port.toString()); hint = "Port"
            inputType = android.text.InputType.TYPE_CLASS_NUMBER
        }
        fields.addView(host); fields.addView(port)
        AlertDialog.Builder(this).setTitle("Change Windows address")
            .setMessage("Use the same paired Windows computer. Its identity will still be checked when connecting.")
            .setView(fields).setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton("Save address") { _, _ ->
                if (sessionView.busy || microphoneView.ownsSession || pendingMicrophoneText != null ||
                    pendingOutputPermission != null || savedState.working) return@setPositiveButton
                try {
                    LanInvitation.validateEndpoint(host.text.toString().trim(), port.text.toString().toInt())
                    if (sessionView.phase == SessionPhase.PAUSED) playback?.stopFromActivity()
                    PausedPlayback.clear(this)
                    savedConnections.updateAddress(host.text.toString().trim(), port.text.toString().toInt())
                } catch (_: Exception) { showConnectionFailure("Use a private IPv4 address and a port from 1 to 65535.") }
            }.show()
    }

    private fun startLocalOutput() {
        if (sessionView.busy || microphoneView.ownsSession || pendingMicrophoneText != null || pendingOutputPermission != null) return
        if (sessionView.phase == SessionPhase.PAUSED) playback?.stopFromActivity()
        hasFocus = audioManager.requestAudioFocus(focusRequest) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        if (!hasFocus) { showConnectionFailure(getString(R.string.focus_denied)); return }
        val current = ++generation
        connectButton.isEnabled = false; localButton.isEnabled = false
        fastRecovery.isEnabled = false; keepMicrophoneActive.isEnabled = false
        invitationInput.isEnabled = false; stopButton.isEnabled = true
        clickButton.isEnabled = true
        localBaseline = null; latestDiagnostics = null; copyButton.isEnabled = false
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        idleMessage = null
        localProbe = LocalOutputProbe({ snapshot -> handler.post {
            if (current == generation) {
                localBaseline = snapshot
                val report = "Local output baseline · phone uptime ${snapshot.capturedUptimeMs} ms\n" +
                    getString(R.string.local_output_instructions) + "\n" + snapshot.text()
                latestDiagnostics = report; copyButton.isEnabled = true; updateControls()
            }
        } }, { message -> handler.post {
            if (current == generation) { stopPlayback(); showConnectionFailure(message) }
        } })
        localProbe?.start()
        updateControls()
    }

    private fun stopPlayback() {
        pairingConnect.cancel()
        if (savedState.pairing) savedConnections.cancelPairing()
        pendingOutputPermission = null; outputPermissionReady = false
        pendingMicrophoneText = null; microphonePermissionReady = false
        pendingInputChoice = null; inputChoiceReady = false
        if (microphoneView.ownsSession) microphone?.stopFromActivity()
        else if (sessionView.retained) playback?.stopFromActivity() else stopLocalPlayback()
    }

    private fun stopLocalPlayback() {
        val hadLocalPlayback = localProbe != null
        ++generation
        localProbe?.close(); localProbe = null
        abandonFocus()
        updateControls()
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (hadLocalPlayback) { idleMessage = null; updateControls() }
    }

    private fun changeOutput(enabled: Boolean) {
        if (!outputEnabled.isEnabled) { updateControls(); return }
        when {
            microphoneView.ownsSession -> microphone?.setOutputEnabled(enabled)
            sessionView.retained -> playback?.setOutputEnabled(enabled)
            else -> preferences = AppAudioSettings.update(this) { it.copy(outputEnabled = enabled) }
        }
        updateControls()
    }

    private fun changeMicrophone(enabled: Boolean) {
        if (!microphoneEnabled.isEnabled) { updateControls(); return }
        if (microphoneView.ownsSession) microphone?.setMuted(!enabled)
        else preferences = AppAudioSettings.update(this) { it.copy(microphoneEnabled = enabled) }
        updateControls()
    }

    private fun updateControls() {
        if (renderingControls) return
        renderingControls = true
        try {
            preferences = AppAudioSettings.load(this)
            val local = localProbe != null
            val idle = !sessionView.busy && !microphoneView.ownsSession && pendingMicrophoneText == null && pendingOutputPermission == null &&
                pendingInputChoice == null && !pendingConnect && !pairingConnect.pending && !local && playback != null && !savedState.working
            if (idle && !sessionView.retained) {
                // Shows idle Windows edits. A wired/USB port chosen in this
                // process comes back exactly while attached (AudioSettingsStore).
                selectedMicrophone = AppAudioSettings.input(this)
                selectedOutput = AppAudioSettings.output(this)
                rememberedInput = selectedMicrophone; rememberedOutput = selectedOutput
            }
            val setupPending = pendingInputChoice != null || pendingMicrophoneText != null || pendingOutputPermission != null || pendingConnect || pairingConnect.pending
            if (!sessionView.retained && !microphoneView.ownsSession) OutputDevices.refresh(this, selectedOutput)?.let {
                selectedOutput = it; rememberedOutput = it
            }
            if (!microphoneView.ownsSession) MicrophoneRouting.refresh(this, selectedMicrophone)?.let {
                selectedMicrophone = it; rememberedInput = it
            }
            val selection = if (microphoneView.ownsSession) microphoneView.input else selectedMicrophone
            val inputNeedsSelection = !microphoneView.ownsSession && preferences.needsInputSelection(selection)
            val current = if (microphoneView.ownsSession || showingMicrophone) microphoneView.session else sessionView
            val mode = when {
                microphoneView.ownsSession -> microphoneView.mode
                sessionView.retained -> StreamMode.PLAYBACK
                else -> null
            }
            volumeControlStream = if (microphoneView.session.active &&
                microphoneView.session.phase != SessionPhase.PAUSING && selection.kind.bluetooth)
                AudioManager.STREAM_VOICE_CALL else AudioManager.STREAM_MUSIC

            outputEnabled.isChecked = if (mode != null) mode.playback && current.outputEnabled else preferences.outputEnabled
            outputEnabled.setText(if (mode?.playback == true && current.outputPaused) R.string.enable_audio_paused
                else R.string.enable_audio)
            outputEnabled.stateDescription = getString(outputStateResource(current, mode))
            outputEnabled.isEnabled = !setupPending && (if (mode != null) mode.playback && current.canSetOutput &&
                (if (mode.microphone) microphone != null else playback != null) else idle)
            val helpResource = when {
                mode != null && !mode.playback -> R.string.output_unavailable
                mode?.microphone == true && selection.kind.bluetooth -> R.string.headset_output_help
                else -> R.string.output_help
            }
            outputHelp.text = (current.outputPause?.takeIf { mode?.playback == true && current.outputEnabled }?.detail?.plus("\n\n") ?: "") + getString(helpResource)
            outputSettingsButton.isEnabled = idle
            outputDeviceButton.isEnabled = !setupPending && (idle || (mode?.playback == true && current.phase in
                listOf(SessionPhase.PLAYING, SessionPhase.RECOVERING, SessionPhase.ROUTE_RECOVERING,
                    SessionPhase.PAUSED, SessionPhase.INTERRUPTED)))
            val outputActionAvailable = canUsePhoneSpeaker() || canFollowAndroidOutput()
            outputActionButton.setText(if (canUsePhoneSpeaker()) R.string.use_phone_speaker else R.string.follow_android_output)
            outputActionButton.visibility = if (outputActionAvailable) android.view.View.VISIBLE else android.view.View.GONE
            outputActionButton.isEnabled = outputDeviceButton.isEnabled && outputActionAvailable
            val outputNeedsSelection = preferences.needsOutputSelection(selectedOutput)
            val outputs = runCatching { OutputDevices.choices(this) }.getOrNull()
            val outputTitle = outputs?.firstOrNull { it.selection == selectedOutput }?.title ?: selectedOutput.kind.label
            outputDeviceButton.text = if (outputNeedsSelection) getString(R.string.choose_output)
                else getString(if (mode?.microphone == true && selection.kind.bluetooth) R.string.next_media_output
                    else R.string.selected_output, outputTitle) +
                    (if (!OutputDevices.available(this, selectedOutput)) " (unavailable)" else "")
            volume.isEnabled = (mode?.playback ?: true) && current.phase != SessionPhase.STOPPING
            updateVolume()

            microphoneEnabled.isChecked = when {
                mode?.microphone == true -> !microphoneView.muted
                mode != null -> false
                else -> preferences.microphoneEnabled
            }
            microphoneEnabled.isEnabled = !setupPending && when {
                mode?.microphone == true -> microphone != null && microphoneView.canSetMuted(!microphoneView.muted)
                mode != null -> false
                else -> idle
            }
            microphoneToggleHelp.setText(when {
                mode != null && !mode.microphone -> R.string.microphone_unavailable
                microphoneView.ownsSession && microphoneView.changing -> R.string.microphone_updating
                inputNeedsSelection -> R.string.microphone_reselect
                else -> R.string.microphone_help
            })
            microphoneInputButton.isEnabled = !setupPending && (idle || (microphone != null && microphoneView.canChooseInput))
            val choices = runCatching { MicrophoneRouting.choices(this) }.getOrNull()
            val inputTitle = choices?.firstOrNull { it.selection.sameDevice(selection) }?.title ?: selection.kind.label
            microphoneInputButton.text = if (inputNeedsSelection) getString(R.string.microphone_input)
                else getString(R.string.selected_microphone, inputTitle) +
                    (if (!microphoneView.ownsSession && !MicrophoneRouting.available(this, selection)) " (unavailable)" else "")
            microphoneInputHelp.text = when {
                selection.leStereoRequested -> "LE Audio stereo playback selected. Changing input or profile briefly reconnects the stream. Echo cancellation is off."
                selection.kind == MicrophoneKind.LE -> "LE Audio mono compatibility playback selected. Changing input or profile briefly reconnects the stream. Echo cancellation is off."
                selection.kind == MicrophoneKind.SCO -> "This Bluetooth microphone uses mono voice playback. Choose the phone microphone for high-quality media listening; input changes briefly reconnect."
                else -> "Input changes briefly reconnect the stream. Use headphones, or try microphone echo reduction when listening through the phone speaker."
            } + when {
                choices == null -> "\nInput availability could not be checked. Tap Microphone input to retry."
                choices.none { it.selection.kind == MicrophoneKind.LE } -> "\nNo LE Audio microphone route is currently available."
                else -> "\nLE Audio microphone route available."
            }
            leStereoPlayback.visibility = if (selection.kind == MicrophoneKind.LE) android.view.View.VISIBLE else android.view.View.GONE
            leStereoPlayback.isEnabled = microphoneInputButton.isEnabled && selection.kind == MicrophoneKind.LE
            leStereoPlayback.isChecked = selection.leStereo
            echoCancellation.isChecked = preferences.echoCancellation
            noiseReduction.isChecked = preferences.noiseReduction
            echoCancellation.isEnabled = idle && !selection.kind.bluetooth && preferences.outputEnabled
            noiseReduction.isEnabled = idle && !selection.kind.bluetooth
            processingHelp.setText(if (selection.kind.bluetooth) R.string.microphone_processing_bluetooth else R.string.microphone_processing_help)
            allowWindowsSettings.isChecked = AppPhoneControlSettings.enabled(this)
            fastRecovery.isChecked = preferences.fastRecovery
            keepMicrophoneActive.isChecked = preferences.keepMicrophoneActive

            val resume = microphoneView.canResume && microphone != null && !setupPending
            val entered = invitationInput.text.toString().trim()
            connectButton.isEnabled = resume || (idle &&
                (!preferences.microphoneEnabled || PairingInvitation.isPairingLink(entered) || microphone != null))
            connectButton.text = when {
                resume -> "Resume duplex"
                pendingConnect || pairingConnect.pending || pendingMicrophoneText != null || pendingOutputPermission != null -> "Connecting…"
                entered.isEmpty() && savedState.available -> "Reconnect"
                else -> getString(R.string.connect)
            }
            scanButton.isEnabled = idle
            discoveryButton.isEnabled = idle
            for (i in 0 until discoveryList.childCount) discoveryList.getChildAt(i).isEnabled = idle
            forgetButton.isEnabled = idle && savedState.present
            cancelPairButton.isEnabled = savedState.pairing
            cancelPairButton.visibility = if (savedState.pairing) android.view.View.VISIBLE else android.view.View.GONE
            addressButton.isEnabled = idle && savedState.paired
            addressButton.visibility = if (savedState.paired) android.view.View.VISIBLE else android.view.View.GONE
            localButton.isEnabled = idle
            fastRecovery.isEnabled = idle
            keepMicrophoneActive.isEnabled = idle
            invitationInput.isEnabled = idle
            clickButton.isEnabled = localProbe != null
            clickButton.visibility = if (localProbe != null) android.view.View.VISIBLE else android.view.View.GONE
            copyButton.isEnabled = latestDiagnostics != null
            val canPause = !microphoneView.ownsSession && !pendingConnect && playback != null && sessionView.phase in
                listOf(SessionPhase.PLAYING, SessionPhase.RECOVERING, SessionPhase.SWITCHING, SessionPhase.INTERRUPTED, SessionPhase.PAUSING)
            pauseButton.visibility = if (canPause) android.view.View.VISIBLE else android.view.View.GONE
            pauseButton.isEnabled = canPause
            pauseButton.text = if (sessionView.phase == SessionPhase.INTERRUPTED) "Keep paused" else getString(R.string.pause)
            stopButton.isEnabled = pairingConnect.pending || savedState.pairing || pendingMicrophoneText != null || pendingInputChoice != null || pendingOutputPermission != null || local ||
                (microphoneView.ownsSession && microphoneView.session.phase != SessionPhase.STOPPING && microphone != null) ||
                (sessionView.retained && sessionView.phase != SessionPhase.STOPPING && playback != null)

            connectionSection.summarize(savedState.message.lineSequence().firstOrNull().orEmpty())
            outputSection.summarize(getString(outputStateResource(current, mode)) + " · " +
                (if (mode?.microphone == true && selection.kind.bluetooth) "selected headset" else
                    if (outputNeedsSelection) getString(R.string.choose_output) else selectedOutput.kind.label))
            microphoneSection.summarize(getString(when {
                microphoneEnabled.isChecked -> R.string.microphone_on
                mode?.microphone == true -> R.string.microphone_muted
                else -> R.string.microphone_off
            }) + " · " + if (inputNeedsSelection) getString(R.string.microphone_input) else selection.kind.label)
            advancedSection.summarize(getString(R.string.advanced_summary,
                ConnectionTimeout.seconds(AppConnectionSettings.load(this)[ConnectionTimeout.RECOVERY])))
            diagnosticsSection.summarize(getString(R.string.version_label, BuildConfig.VERSION_NAME))
            renderStatus(local, current, mode)
        } finally { renderingControls = false }
    }

    private fun updateVolume() {
        runCatching {
            volume.min = audioManager.getStreamMinVolume(volumeControlStream)
            volume.max = audioManager.getStreamMaxVolume(volumeControlStream)
            volume.progress = audioManager.getStreamVolume(volumeControlStream)
            volumeLabel.text = getString(if (volumeControlStream == AudioManager.STREAM_VOICE_CALL)
                R.string.voice_volume else R.string.media_volume, volume.progress, volume.max)
        }.onFailure { volume.isEnabled = false; volumeLabel.setText(R.string.playback_volume) }
    }

    private fun outputStateResource(current: SessionView, mode: StreamMode?): Int = when {
        !outputEnabled.isChecked -> R.string.audio_silenced
        mode?.playback == true && current.outputPaused -> R.string.audio_paused
        else -> R.string.audio_on
    }

    private fun renderStatus(local: Boolean, current: SessionView, mode: StreamMode?) {
        statusTitle.text = when {
            local -> "Local audio test"
            pendingConnect -> "Connecting"
            pendingMicrophoneText != null -> "Microphone permission"
            pendingInputChoice != null -> "Input permission"
            pendingOutputPermission != null -> "Bluetooth output permission"
            savedState.pairing -> "Pairing with Windows"
            mode != null && idleMessage != null -> "Device selection needs attention"
            mode != null && current.phase == SessionPhase.PLAYING -> "Connected"
            mode != null -> current.phase.label
            idleMessage != null -> "Connection needs attention"
            current.phase == SessionPhase.ENDED -> current.phase.label
            else -> "Ready"
        }
        val controls = listOf(
            getString(outputStateResource(current, mode)),
            getString(if (microphoneEnabled.isChecked) R.string.microphone_on
                else if (mode?.microphone == true) R.string.microphone_muted else R.string.microphone_off)).joinToString(" · ")
        val message = current.message.takeUnless { it.contains(" snapshot:") }
        statusView.text = when {
            local -> getString(R.string.local_output_status)
            pendingMicrophoneText != null -> "Allow microphone access to continue, or Stop to cancel."
            pendingInputChoice != null -> "Allow the requested permissions to change input, or Stop to cancel."
            pendingOutputPermission != null -> "Allow Nearby devices access for the selected output, or Stop to cancel."
            savedState.pairing -> savedState.message
            mode != null -> listOf(current.destination, current.networkStatus, controls,
                current.outputPause?.takeIf { mode.playback && current.outputEnabled }?.detail,
                idleMessage ?: message.takeUnless { current.phase == SessionPhase.PLAYING }).filterNotNull().filter { it.isNotBlank() }.joinToString("\n")
            idleMessage != null -> idleMessage
            current.phase == SessionPhase.ENDED -> message?.lineSequence()?.firstOrNull() ?: "Stopped."
            else -> "$controls\nConnect uses these options."
        }
        val details = listOfNotNull(idleMessage, message.takeIf { current.phase == SessionPhase.ENDED }, latestDiagnostics)
            .distinct().joinToString("\n\n")
        diagnosticsView.text = details.ifBlank { getString(R.string.no_report) }
    }

    private fun abandonFocus() {
        if (hasFocus) { audioManager.abandonAudioFocusRequest(focusRequest); hasFocus = false }
    }

    private companion object {
        // Selection survives activity recreation, never process death. Saving
        // only an input kind cannot authorize a different physical headset.
        var rememberedInput: MicrophoneSelection? = null
        var rememberedOutput: OutputSelection? = null
    }
}
