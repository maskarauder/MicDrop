// The single main screen (`MainActivity.kt:282-525`).
//
// Scroll view with the header, status card and five collapsible sections (Connection setup, Audio output,
// Microphone, Advanced, Diagnostics); a persistent action bar (`Connect | Stop`, then `Pause playback`)
// outside the scroll view, kept above the keyboard by `.safeAreaInset(edge: .bottom)`; toasts above the
// action bar; dialogs, alerts, the scanner cover and the notices sheet. Section expansion persists in
// `@SceneStorage` (`section.connection` … `section.diagnostics`).

import MicDropCore
import SwiftUI

struct MainView: View {
    @Bindable var model: MainViewModel

    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("section.connection") private var connectionExpanded = true
    @SceneStorage("section.output") private var outputExpanded = false
    @SceneStorage("section.microphone") private var microphoneExpanded = false
    @SceneStorage("section.advanced") private var advancedExpanded = false
    @SceneStorage("section.diagnostics") private var diagnosticsExpanded = false
    @FocusState private var invitationFocused: Bool

    init(model: MainViewModel) {
        self.model = model
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    HeaderView()
                    StatusCardView(model: model)
                        .padding(.bottom, 8)
                    VStack(spacing: 12) {
                        SettingsSectionView(
                            .connection, summary: model.render.connectionSummary,
                            expanded: $connectionExpanded
                        ) {
                            ConnectionSectionView(model: model, invitationFocused: $invitationFocused)
                        }
                        .id(SettingsSectionID.connection)
                        SettingsSectionView(
                            .output, summary: model.render.outputSummary,
                            expanded: $outputExpanded
                        ) {
                            OutputSectionView(model: model)
                        }
                        .id(SettingsSectionID.output)
                        SettingsSectionView(
                            .microphone, summary: model.render.microphoneSummary,
                            expanded: $microphoneExpanded
                        ) {
                            MicrophoneSectionView(model: model)
                        }
                        .id(SettingsSectionID.microphone)
                        SettingsSectionView(
                            .advanced, summary: model.render.advancedSummary,
                            expanded: $advancedExpanded
                        ) {
                            AdvancedSectionView(model: model)
                        }
                        .id(SettingsSectionID.advanced)
                        SettingsSectionView(
                            .diagnostics, summary: model.render.diagnosticsSummary,
                            expanded: $diagnosticsExpanded
                        ) {
                            DiagnosticsSectionView(model: model)
                        }
                        .id(SettingsSectionID.diagnostics)
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.sectionRequest) { _, request in
                guard let request else { return }
                setExpanded(request.section)
                withAnimation { proxy.scrollTo(request.section, anchor: .top) }
            }
        }
        .overlay(alignment: .bottom) {
            ToastOverlay(center: model.toasts)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ActionBarView(model: model)
        }
        .background(Theme.appBackground.ignoresSafeArea())
        .tint(Theme.accent)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { invitationFocused = false }
            }
        }
        .onChange(of: model.invitationFocusRequest) { _, _ in
            invitationFocused = true
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.scenePhaseChanged(phase)
        }
        // Media output list; iOS replaces Android's "Device missing?" button with a message that points to the picker
        // row (D042).
        .confirmationDialog(
            Strings.chooseOutput,
            isPresented: Binding(
                get: { model.outputChoicesDialog != nil },
                set: { if !$0 { model.outputChoicesDialog = nil } }),
            titleVisibility: .visible,
            presenting: model.outputChoicesDialog
        ) { choices in
            ForEach(choices) { choice in
                Button(choice.title) { model.chooseOutput(choice) }
            }
            Button(Strings.cancel, role: .cancel) {}
        } message: { _ in
            Text(model.render.outputDialogMessage)
        }
        // Microphone input list; iOS replaces Android's "Bluetooth settings" button with a message.
        .confirmationDialog(
            Strings.microphoneDialogTitle,
            isPresented: Binding(
                get: { model.inputChoicesDialog != nil },
                set: { if !$0 { model.inputChoicesDialog = nil } }),
            titleVisibility: .visible,
            presenting: model.inputChoicesDialog
        ) { choices in
            ForEach(choices) { choice in
                Button(choice.title) { model.chooseMicrophone(choice) }
            }
            Button(Strings.cancel, role: .cancel) {}
        } message: { _ in
            Text(model.render.inputDialogMessage)
        }
        // Discovered host: saved candidate or pair first.
        .alert(
            model.discoveryAlert?.title ?? "",
            isPresented: Binding(
                get: { model.discoveryAlert != nil },
                set: { if !$0 { model.discoveryAlert = nil } }),
            presenting: model.discoveryAlert
        ) { alert in
            switch alert {
            case .savedHost(let host):
                Button(Strings.cancel, role: .cancel) {}
                Button(Strings.connect) { model.confirmDiscoveredConnect(host) }
            case .unknownHost:
                Button(Strings.cancel, role: .cancel) {}
                Button(Strings.discoveryPaste) { model.pasteFromDiscoveryDialog() }
                Button(Strings.scanPairing) { model.scanFromDiscoveryDialog() }
            }
        } message: { alert in
            Text(alert.message)
        }
        // Change Windows address.
        .alert(
            Strings.changeAddress,
            isPresented: Binding(
                get: { model.addressForm != nil },
                set: { if !$0 { model.addressForm = nil } })
        ) {
            TextField(Strings.addressHostHint, text: addressHostBinding)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField(Strings.addressPortHint, text: addressPortBinding)
                .keyboardType(.numberPad)
            Button(Strings.cancel, role: .cancel) {}
            Button(Strings.saveAddress) {
                let form = model.addressForm
                model.saveAddress(host: form?.host ?? "", port: form?.port ?? "")
            }
        } message: {
            Text(Strings.changeAddressMessage)
        }
        .fullScreenCover(isPresented: $model.scannerPresented, onDismiss: { model.scannerDismissed() }) {
            QRScannerScreen { result in model.scannerFinished(result) }
        }
        .sheet(isPresented: $model.noticesPresented) {
            NoticesView()
        }
    }

    private var addressHostBinding: Binding<String> {
        Binding(
            get: { model.addressForm?.host ?? "" },
            set: { model.addressForm?.host = $0 })
    }

    private var addressPortBinding: Binding<String> {
        Binding(
            get: { model.addressForm?.port ?? "" },
            set: { model.addressForm?.port = $0 })
    }

    private func setExpanded(_ section: SettingsSectionID) {
        switch section {
        case .connection: connectionExpanded = true
        case .output: outputExpanded = true
        case .microphone: microphoneExpanded = true
        case .advanced: advancedExpanded = true
        case .diagnostics: diagnosticsExpanded = true
        }
    }
}

/// Title (accent, `MainActivity.kt:295-300`) and subtitle.
struct HeaderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Strings.appName)
                .font(Theme.titleFont)
                .foregroundStyle(Theme.accent)
                .accessibilityAddTraits(.isHeader)
            // `help(R.string.subtitle)` with its padding replaced by 0/0/0/12 (`MainActivity.kt:301`).
            HelpText(Strings.subtitle, padded: false)
                .padding(.bottom, 12)
        }
    }
}
