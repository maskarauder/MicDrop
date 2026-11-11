// Camera capture for the pairing QR (`MainActivity.kt:616-627`, `third_party/QR.md`).
//
// AVCaptureSession (preset 1920x1080 for dense terminal codes) with the back wide-angle camera, continuous autofocus
// restricted to near range when supported, an aspect-fill preview, and an AVCaptureVideoDataOutput (420f, late frames
// discarded) on a serial queue. At most ~10 frames per second are decoded, alternating raw and inverted frames
// (MIXED_SCAN). No frame or image is saved, logged or put in a report; no sound. Camera permission is handled before
// presentation.

import AVFoundation
import CoreImage
import QuartzCore
import UIKit

/// Hosts the capture session and preview; delivers the first decoded payload once.
final class QRScannerController: UIViewController {
    /// Called on the main actor with the first decoded payload (any QR text).
    var onDecoded: ((String) -> Void)?
    /// Called on the main actor when the camera could not be configured.
    var onUnavailable: (() -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.maskarauder.micdrop.qr.session")
    private let videoQueue = DispatchQueue(label: "com.maskarauder.micdrop.qr.video")
    private let processor = QRFrameProcessor()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var configured = false
    private var wantsRunning = false
    private var delivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        processor.onPayload = { @Sendable [weak self] payload in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.deliver(payload) }
            }
        }
        configure()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setRunning(true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        setRunning(false)
    }

    /// Scene activity (lifecycle): stop when the scene leaves `.active`, restart when it is active again and the
    /// scanner is still presented.
    func setActive(_ active: Bool) {
        setRunning(active && view.window != nil)
    }

    // MARK: Private

    private func configure() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device)
        else {
            reportUnavailable()
            return
        }
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            reportUnavailable()
            return
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(processor, queue: videoQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            reportUnavailable()
            return
        }
        session.addOutput(output)
        session.commitConfiguration()

        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .near
            }
            device.unlockForConfiguration()
        }

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        // Portrait and landscape: keep the preview level with the horizon (iOS 17 rotation coordinator).
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyPreviewRotation(angle) }
            }
        }
        configured = true
        if wantsRunning { startSession() }
    }

    /// Reported on the next main-queue turn so SwiftUI never sees a state change during a view update.
    private func reportUnavailable() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onUnavailable?() }
        }
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    private func setRunning(_ running: Bool) {
        wantsRunning = running && !delivered
        guard configured else { return }
        if wantsRunning { startSession() } else { stopSession() }
    }

    private func startSession() {
        let session = self.session
        sessionQueue.async {
            if !session.isRunning { session.startRunning() }
        }
    }

    private func stopSession() {
        let session = self.session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    private func deliver(_ payload: String) {
        guard !delivered else { return }
        delivered = true
        wantsRunning = false
        stopSession()
        onDecoded?(payload)
    }
}

/// Video-queue frame handler: throttles to ~10 frames/s and alternates polarity. All state is touched
/// only on the video queue (hence `@unchecked Sendable`).
private final class QRFrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Minimum spacing between decoded frames (~10 frames/s).
    static let frameInterval: CFTimeInterval = 0.1

    /// Called on the video queue with the first payload.
    var onPayload: (@Sendable (String) -> Void)?

    private let decoder = QRFrameDecoder()
    private var lastFrame: CFTimeInterval = 0
    private var invertNext = false
    private var finished = false

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !finished, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()
        guard now - lastFrame >= Self.frameInterval else { return }
        lastFrame = now
        let inverted = invertNext
        invertNext.toggle()
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        if let payload = decoder.decodeAlternating(image, inverted: inverted) {
            finished = true
            onPayload?(payload)
        }
    }
}
