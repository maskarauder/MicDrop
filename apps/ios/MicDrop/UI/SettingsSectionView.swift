// Collapsible settings card (`SettingsSection.kt:9-54`, `MainActivity.kt:331-342`, `:592-597`).

import MicDropCore
import SwiftUI

/// The five sections of the main screen in Android's order (`listOf(connectionSection, outputSection,
/// microphoneSection, advancedSection, diagnosticsSection)`), with their persisted expansion keys and defaults.
enum SettingsSectionID: String, CaseIterable, Hashable, Sendable {
    case connection
    case output
    case microphone
    case advanced
    case diagnostics

    /// `@SceneStorage` key (Android instance-state key): `section.connection` etc. Like Android, the former
    /// `section.debugging` key is not read (no migration).
    var storageKey: String { "section." + rawValue }

    /// Connection setup starts expanded; the others start collapsed.
    var defaultExpanded: Bool { self == .connection }

    /// `strings.xml:11,12,19,20,25`.
    var title: String {
        switch self {
        case .connection: return Strings.connectionSetup
        case .output: return Strings.audioOutput
        case .microphone: return Strings.microphone
        case .advanced: return Strings.advanced
        case .diagnostics: return Strings.diagnostics
        }
    }
}

/// A programmatic "expand and scroll to" request from the view model (Android `expand(true)` when an
/// error needs attention). `serial` makes repeated requests for the same section observable.
struct SectionRequest: Equatable, Sendable {
    let section: SettingsSectionID
    let serial: UInt64
}

/// Header button (`"<title>  ▾"` / `"<title>  ▸"`; accent while expanded, primary text while collapsed), the
/// summary line (hidden while the summary is blank, `summarize`) and the body while expanded. Accessibility: header
/// trait, label = title, value `Expanded` / `Collapsed`.
struct SettingsSectionView<Content: View>: View {
    let section: SettingsSectionID
    let summary: String
    @Binding var expanded: Bool
    let content: Content

    init(
        _ section: SettingsSectionID, summary: String, expanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.section = section
        self.summary = summary
        self._expanded = expanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                // `expand`: accent while expanded, else primary text (`SettingsSection.kt:44`).
                Text(Strings.sectionHeader(section.title, expanded: expanded))
                    .font(Theme.sectionHeaderFont)
                    .foregroundStyle(expanded ? Theme.accent : Theme.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: Theme.minimumTouchTarget, alignment: .leading)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Theme.surface)
            .accessibilityLabel(section.title)
            .accessibilityValue(expanded ? Strings.sectionExpanded : Strings.sectionCollapsed)
            .accessibilityAddTraits(.isHeader)

            // Summary: padding 12/0/12/8 (`SettingsSection.kt:19-23`), gone while blank (`:49-52`).
            if !summary.allSatisfy(\.isWhitespace) {
                HelpText(summary, padded: false)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            if expanded {
                // Body: padding 12/4/12/12 (`SettingsSection.kt:24-27`).
                VStack(alignment: .leading, spacing: 10) {
                    content
                }
                .padding(EdgeInsets(top: 4, leading: 12, bottom: 12, trailing: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCard()
    }
}
