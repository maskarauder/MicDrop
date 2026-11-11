// Color tokens, typography, the card and the button styles (`res/values/colors.xml`, `res/values/styles.xml`,
// `res/color/button_surface.xml`, `res/color/button_primary.xml`, `res/drawable/settings_card.xml`).

import SwiftUI
import UIKit

/// The MicDrop palette: the Windows desktop's dark slate and gold in both system appearances (removed Android's
/// `values-night` resources; `Theme.MicDrop` is now `Theme.Material.NoActionBar` with `windowLightStatusBar` false).
/// The app forces the dark appearance (`MicDropApp`, Info.plist `UIUserInterfaceStyle`), so the status bar, alerts,
/// confirmation dialogs, sheets and the keyboard match.
enum Theme {
    /// Window background (`#202831`).
    static let appBackground = color(0x202831)
    /// Cards, section headers, toasts and the notices sheet (`#2A3541`).
    static let surface = color(0x2A3541)
    /// Card, toast and text field stroke (`#394551`).
    static let surfaceBorder = color(0x394551)
    /// Title, status title, expanded section headers, Connect, toggles and the text field tint (`#D4AC45`).
    static let accent = color(0xD4AC45)
    /// Body text and collapsed section headers (`#E9EEF2`).
    static let textPrimary = color(0xE9EEF2)
    /// Help, summaries, diagnostics and the invitation hint (`#BDC8D2`).
    static let textSecondary = color(0xBDC8D2)
    /// Disabled text field text and hint, disabled route picker row (`#8F9EAE`).
    static let textDisabled = color(0x8F9EAE)
    /// Surface button fill (`control_surface`, `#8F9EAE`).
    static let controlSurface = color(0x8F9EAE)
    /// Disabled fill of both button styles (`control_disabled`, `#6F7E8E`).
    static let controlDisabled = color(0x6F7E8E)
    /// Button text (`on_control`, `#000000`).
    static let onControl = color(0x000000)
    /// Pressed button overlay (`control_highlight`, `#33D4AC45`: the accent at alpha 0x33).
    static let controlHighlight = color(0xD4AC45, alpha: 0x33)

    /// UIKit accent for `AVRoutePickerView.activeTintColor` and the volume slider.
    static let accentUIColor = uiColor(0xD4AC45)

    // MARK: Typography (Android sp → iOS points, scaled with Dynamic Type)

    /// Title 28 sp → `.title` medium.
    static let titleFont = Font.title.weight(.medium)
    /// Section header 17 sp → `.body`.
    static let sectionHeaderFont = Font.body
    /// Status text 15 sp → `.subheadline`.
    static let statusTextFont = Font.subheadline
    /// Diagnostics 12 sp → `.caption` monospaced.
    static let diagnosticsFont = Font.system(.caption, design: .monospaced)
    /// Status title 18 pt, scaled relative to `.title3` (use with `@ScaledMetric`).
    static let statusTitleSize: CGFloat = 18
    /// Help / summary 14 pt, scaled relative to `.subheadline` (use with `@ScaledMetric`).
    static let helpSize: CGFloat = 14
    /// Minimum touch target (Android 48 dp → 44 pt).
    static let minimumTouchTarget: CGFloat = 44

    // MARK: Card (`settings_card.xml`: surface fill, 1 dp border, 12 dp corners)

    static let cardCornerRadius: CGFloat = 12

    // MARK: Buttons (`Widget.MicDrop.Button`)

    static let controlCornerRadius: CGFloat = 8

    private static func color(_ rgb: UInt32, alpha: UInt32 = 0xFF) -> Color {
        Color(uiColor: uiColor(rgb, alpha: alpha))
    }

    private static func uiColor(_ rgb: UInt32, alpha: UInt32 = 0xFF) -> UIColor {
        UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: CGFloat(alpha & 0xFF) / 255)
    }
}

/// The `settings_card` background: surface fill, 1 pt `surfaceBorder` stroke, 12 pt corners.
struct SettingsCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .stroke(Theme.surfaceBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
    }
}

/// "Help style" text: 14 pt relative to `.subheadline`, `textSecondary`, leading, wrapping. In a section body it is
/// padded 4 pt above and 8 pt below (Android `help()`, `MainActivity.kt:532-536`); the subtitle and the section
/// summaries pass `padded: false` and keep their own padding.
struct HelpText: View {
    let text: String
    let padded: Bool
    @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = Theme.helpSize

    init(_ text: String, padded: Bool = true) {
        self.text = text
        self.padded = padded
    }

    var body: some View {
        Text(text)
            .font(.system(size: size))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, padded ? 4 : 0)
            .padding(.bottom, padded ? 8 : 0)
    }
}

/// A full-width button label with up to two lines of text and a 44 pt minimum height with the button styles'
/// padding (Android buttons: not all caps, up to 2 lines, 48 dp).
struct WideButtonLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: Theme.minimumTouchTarget - 16)
    }
}

/// The app's full-width buttons other than Connect (`Widget.MicDrop.Button`, `res/color/button_surface.xml`):
/// `controlSurface` fill, `onControl` text, `controlDisabled` fill while disabled. Section headers stay `.plain` and
/// the Open Settings links `.borderless`.
struct SurfaceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ControlButtonBody(configuration: configuration, fill: Theme.controlSurface)
    }
}

/// Connect (`backgroundTintList = button_primary`, `MainActivity.kt:321-323`; `res/color/button_primary.xml`):
/// `accent` fill, `onControl` semibold text, `controlDisabled` fill while disabled.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ControlButtonBody(configuration: configuration, fill: Theme.accent)
            .font(.body.weight(.semibold))
    }
}

/// The shared body of both button styles: 44 pt minimum height and 8 pt corners; while pressed, the
/// `controlHighlight` overlay (`colorControlHighlight`) and a slight fade, which also shows on the gold fill. Reads
/// `isEnabled` inside the button, where `.disabled` reaches it.
private struct ControlButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let fill: Color
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlCornerRadius, style: .continuous)
        configuration.label
            .foregroundStyle(Theme.onControl)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(minHeight: Theme.minimumTouchTarget)
            .background(shape.fill(isEnabled ? fill : Theme.controlDisabled))
            .overlay(shape.fill(configuration.isPressed ? Theme.controlHighlight : Color.clear))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(shape)
    }
}

extension View {
    /// Applies `SettingsCardModifier`.
    func settingsCard() -> some View {
        modifier(SettingsCardModifier())
    }
}
