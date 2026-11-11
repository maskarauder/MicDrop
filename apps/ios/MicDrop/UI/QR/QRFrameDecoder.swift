// QR decoding with polarity alternation.
//
// Android uses ZXing `MIXED_SCAN` (alternate normal and inverted luminance each attempt) so dark and light terminal
// themes both decode. Neither AVFoundation metadata output nor VisionKit documents decoding inverted (light-on-dark)
// codes, so frames are alternated between the raw image and a `CIColorInvert` copy and decoded with Vision
// `VNDetectBarcodesRequest` (QR only). Reusable by the fixture test.

import CoreImage
import Foundation
import Vision

/// What the scanner screen returns. Any decoded QR text is returned; validation happens after dismissal
/// (`PairingInvitation.parse`).
enum QRScanResult: Equatable, Sendable {
    case decoded(String)
    case cancelled
    /// iOS-only: the capture session could not be configured ("presentation failure": scan status and toast `Camera
    /// unavailable. Paste the Windows link instead.`).
    case cameraUnavailable
}

/// Stateless Vision QR decoder.
struct QRFrameDecoder {
    /// The first QR observation with a non-nil `payloadStringValue`, or nil.
    func decode(_ image: CIImage) -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observations = request.results else { return nil }
        for observation in observations {
            if let payload = observation.payloadStringValue { return payload }
        }
        return nil
    }

    /// Decodes `image` as-is (`inverted == false`) or its `CIColorInvert` copy (`inverted == true`).
    /// The scanner alternates `inverted` frame by frame.
    func decodeAlternating(_ image: CIImage, inverted: Bool) -> String? {
        decode(inverted ? image.applyingFilter("CIColorInvert") : image)
    }

    /// Fixture/test helper: tries the raw image, then the inverted one.
    func decodeEitherPolarity(_ image: CIImage) -> String? {
        decode(image) ?? decodeAlternating(image, inverted: true)
    }
}
