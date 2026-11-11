import AVKit
import SwiftUI
import UIKit

/// SwiftUI wrapper of `AVRoutePickerView`, the system AirPlay/Bluetooth output picker (row 6 "AirPlay & Bluetooth
/// output…"). This is the `RoutePickerView` representable; composes the row label and caption around it.
///
/// - The user must tap the view itself: iOS has no public API to open the picker programmatically.
/// - `prioritizesVideoDevices = false` (audio-first list), `activeTintColor` = accent.
/// - Enabled per `ControlsRender.systemOutputPickerEnabled` (D042; computed by
/// `ControlsDeriver`): while following the system route wherever the output menu is, with a pinned output only while no
/// session is retained, and never during a Bluetooth headset microphone session. While disabled the view ignores
/// touches, is dimmed and reports `.notEnabled`; renders the Stop caption (`Strings.routePickerPinnedCaption` or
/// `routePickerHeadsetCaption`). A picker choice never changes the selection or the remembered device: it arrives as a
/// route change, handled by the default policy (or the temporary-speaker return) while following the system route, or
/// re-resolving an idle pin.
/// - There is no combined Stop-and-open: the action-bar Stop is the explicit step, and the next render
///   enables the row.
/// - No permission is needed; never treat the picker or `AVRouteDetector` as inventory.
struct SystemRoutePickerView: UIViewRepresentable {
    var isEnabled: Bool
    var activeTintColor: UIColor?
    var tintColor: UIColor?
    /// VoiceOver label of the picker glyph (the row label is rendered by app-ui).
    var accessibilityText: String?
    /// `routePickerViewWillBeginPresentingRoutes` (e.g. to record a control event).
    var onWillPresent: (() -> Void)?
    /// `routePickerViewDidEndPresentingRoutes`.
    var onDidDismiss: (() -> Void)?

    init(
        isEnabled: Bool = true, activeTintColor: UIColor? = nil, tintColor: UIColor? = nil,
        accessibilityText: String? = nil, onWillPresent: (() -> Void)? = nil, onDidDismiss: (() -> Void)? = nil
    ) {
        self.isEnabled = isEnabled
        self.activeTintColor = activeTintColor
        self.tintColor = tintColor
        self.accessibilityText = accessibilityText
        self.onWillPresent = onWillPresent
        self.onDidDismiss = onDidDismiss
    }

    /// Alpha of the disabled picker glyph.
    static let disabledAlpha: CGFloat = 0.4

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView(frame: .zero)
        picker.prioritizesVideoDevices = false
        picker.delegate = context.coordinator
        configure(picker, coordinator: context.coordinator)
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        configure(uiView, coordinator: context.coordinator)
    }

    private func configure(_ picker: AVRoutePickerView, coordinator: Coordinator) {
        coordinator.onWillPresent = onWillPresent
        coordinator.onDidDismiss = onDidDismiss
        picker.isUserInteractionEnabled = isEnabled
        picker.alpha = isEnabled ? 1 : SystemRoutePickerView.disabledAlpha
        if let activeTintColor { picker.activeTintColor = activeTintColor }
        if let tintColor { picker.tintColor = tintColor }
        picker.accessibilityLabel = accessibilityText
        picker.accessibilityTraits = isEnabled ? [.button] : [.button, .notEnabled]
    }

    /// `AVRoutePickerViewDelegate` adapter forwarding presentation callbacks.
    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var onWillPresent: (() -> Void)?
        var onDidDismiss: (() -> Void)?

        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            onWillPresent?()
        }

        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            onDidDismiss?()
        }
    }
}
