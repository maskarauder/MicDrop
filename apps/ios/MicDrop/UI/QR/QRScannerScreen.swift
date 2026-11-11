// Full-screen QR scanner: camera preview, the iOS prompt and a Cancel button.

import MicDropCore
import SwiftUI

/// Presented with `.fullScreenCover`. Returns `.decoded(payload)` on the first QR read (any content)
/// or `.cancelled`; the caller validates after dismissal.
struct QRScannerScreen: View {
    let onFinish: (QRScanResult) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var finished = false

    init(onFinish: @escaping (QRScanResult) -> Void) {
        self.onFinish = onFinish
    }

    var body: some View {
        ZStack {
            QRCameraView(
                active: scenePhase == .active,
                onDecoded: { finish(.decoded($0)) },
                onUnavailable: { finish(.cameraUnavailable) }
            )
            .ignoresSafeArea()
            .accessibilityHidden(true)

            VStack(spacing: 0) {
                HStack {
                    // Top-leading Cancel.
                    Button(Strings.cancel) { finish(.cancelled) }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.black.opacity(0.55))
                        .foregroundStyle(Color.white)
                    Spacer()
                }
                .padding(16)
                Spacer()
                Text(Strings.scanPrompt)
                    .font(.callout)
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.6)))
                    .padding(16)
            }
        }
        .background(Color.black.ignoresSafeArea())
    }

    private func finish(_ result: QRScanResult) {
        guard !finished else { return }
        finished = true
        onFinish(result)
    }
}

/// `QRScannerController` bridged into SwiftUI.
private struct QRCameraView: UIViewControllerRepresentable {
    let active: Bool
    let onDecoded: (String) -> Void
    let onUnavailable: () -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        controller.onDecoded = onDecoded
        controller.onUnavailable = onUnavailable
        return controller
    }

    func updateUIViewController(_ controller: QRScannerController, context: Context) {
        controller.onDecoded = onDecoded
        controller.onUnavailable = onUnavailable
        controller.setActive(active)
    }
}
