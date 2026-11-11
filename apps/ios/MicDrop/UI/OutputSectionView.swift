// Audio output section body (`MainActivity.kt:398-425`).

import MediaPlayer
import MicDropCore
import SwiftUI
import UIKit

/// `Play desktop audio`, the media output button, help, the volume label and system slider, and the
/// iOS `AirPlay & Bluetooth output…` route picker row (replaces Android's sound-settings button).
struct OutputSectionView: View {
    let model: MainViewModel

    var body: some View {
        let render = model.render
        VStack(alignment: .leading, spacing: 10) {
            // 1. Output toggle; a11y value "Audio on" / "Audio silenced" / "Audio paused".
            Toggle(
                isOn: Binding(
                    get: { model.render.outputChecked },
                    set: { model.changeOutput($0) })
            ) {
                Text(render.outputToggleLabel)
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(minHeight: Theme.minimumTouchTarget)
            .disabled(!render.outputToggleEnabled)
            .accessibilityValue(render.outputStateText)
            // 2. Media output list.
            Button {
                model.outputDeviceTapped()
            } label: {
                WideButtonLabel(render.outputDeviceLabel)
            }
            .buttonStyle(SurfaceButtonStyle())
            .disabled(!render.outputDeviceEnabled)
            // 3. Help.
            HelpText(render.outputHelp)
            // 4-5. Volume label and the system volume slider (iOS cannot set the volume otherwise).
            HelpText(render.volumeLabel)
            SystemVolumeView()
                .frame(height: Theme.minimumTouchTarget)
                .disabled(!render.volumeEnabled)
                .accessibilityLabel(Strings.playbackVolume)
            // 6. System output picker (D042 enable rule; pinned, headset and idle-pin captions).
            HStack(spacing: 12) {
                Text(Strings.routePickerRow)
                    .foregroundStyle(render.systemOutputPickerEnabled ? Theme.textPrimary : Theme.textDisabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SystemRoutePickerView(
                    isEnabled: render.systemOutputPickerEnabled,
                    activeTintColor: Theme.accentUIColor,
                    tintColor: Theme.accentUIColor,
                    accessibilityText: Strings.routePickerRow
                )
                .frame(width: Theme.minimumTouchTarget, height: Theme.minimumTouchTarget)
            }
            .frame(minHeight: Theme.minimumTouchTarget)
            if let caption = render.systemOutputPickerCaption {
                HelpText(caption)
            }
        }
    }
}

/// `MPVolumeView` (system volume slider) bridged into SwiftUI. The output route button is hidden (the separate
/// `SystemRoutePickerView` row owns route changes). SwiftUI's `.disabled` is applied to the UIKit view through the
/// `isEnabled` environment value.
struct SystemVolumeView: UIViewRepresentable {
    /// Alpha of the slider while disabled.
    static let disabledAlpha: CGFloat = 0.4

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        // Deprecated since iOS 13 in favour of AVRoutePickerView, still the only way to hide the
        // slider's own route button; the picker row provides route selection.
        view.showsRouteButton = false
        view.tintColor = Theme.accentUIColor
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        let enabled = context.environment.isEnabled
        view.isUserInteractionEnabled = enabled
        view.alpha = enabled ? 1 : SystemVolumeView.disabledAlpha
    }
}
