// Local output probe click: the 10 ms tapered chirp of `LocalOutputProbe.kt:57-65`., Appendix B.7. The app's
// `LocalOutputProbe` (AVAudioSourceNode, 48 kHz stereo Float32) writes zeros, or this chirp when its single
// pending-click flag is set (atomic test-and-clear; at most one pending click, never a queue).

import Foundation

/// The click waveform: 480 frames at 48 kHz (one 10 ms block of 960 interleaved PCM16 samples),
/// `trunc(1638 × sin²(π·i/479) × sin(2π(800·t + 60000·t²)))`, `t = i/48000`, both channels equal
/// (≈ −26 dBFS peak, 800 Hz rising to 2 kHz).
public enum ClickChirp {
    /// Chirp length in frames (`for (i in 0 until 480)`).
    public static let frames = 480
    /// Sample rate the chirp is defined at (the probe's fixed 48 kHz format).
    public static let sampleRate = 48_000
    /// Peak amplitude in PCM16 units (`1638`, 0.05 of full scale).
    public static let peak: Int16 = 1638

    /// Kotlin `(1638 * sin(PI * i / 479).let { it * it } * sin(2 * PI * (800 * t + 60000 * t * t))).toInt().toShort()`
    /// with `t = i / 48000.0`; evaluation order kept (left-associative). Returns 0 outside `0..<frames`.
    /// Vectors: `sample(0) == 0`, `sample(479) == 0`, every `|sample| <= 1638`.
    public static func sample(_ i: Int) -> Int16 {
        guard i >= 0, i < frames else { return 0 }
        let t = Double(i) / 48_000
        let w = sin(Double.pi * Double(i) / 479)
        let value = 1638 * (w * w) * sin(2 * Double.pi * (800 * t + 60_000 * t * t))
        return Int16(Int(value))  // toInt() truncates toward zero; |value| <= 1638 fits Int16
    }

    /// Float form used by the AVAudioSourceNode render block: the same integer sample / 32768 (`Float(trunc(...)) /
    /// 32768`).
    public static func floatSample(_ i: Int) -> Float {
        return Float(sample(i)) / 32_768
    }

    /// Precomputed PCM16 chirp (`frames` values). Touch once before audio starts so the lazy
    /// global initialisation never runs on the real-time thread.
    public static let samples: [Int16] = (0..<ClickChirp.frames).map { ClickChirp.sample($0) }

    /// Precomputed Float chirp (`samples[i] / 32768`).
    public static let floatSamples: [Float] = ClickChirp.samples.map { Float($0) / 32_768 }

    /// The Android 10 ms write block with a click: 960 interleaved PCM16 samples, both channels
    /// equal (`block[2*i] = block[2*i+1] = sample`). Parity fixture for tests.
    public static func stereoBlock() -> [Int16] {
        var block = [Int16](repeating: 0, count: frames * 2)
        var i = 0
        while i < frames {
            let s = samples[i]
            block[2 * i] = s
            block[2 * i + 1] = s
            i += 1
        }
        return block
    }

    /// Writes chirp frames `startFrame ..< startFrame + n` into the first `n` frames of `output`
    /// (interleaved, every channel equal), where `n = min(frames - startFrame, output.count / channels)`.
    /// Remaining output is left untouched (the caller zero-fills). Returns `n`; 0 when
    /// `channels < 1`, `startFrame < 0` or the chirp is finished. Lets a render callback whose
    /// buffer size differs from 480 frames continue the chirp across callbacks; for
    /// non-interleaved buffers call it once per channel buffer with `channels: 1`.
    @discardableResult
    public static func render(
        into output: UnsafeMutableBufferPointer<Float>, channels: Int,
        startFrame: Int
    ) -> Int {
        guard channels >= 1, startFrame >= 0, startFrame < frames else { return 0 }
        let count = min(frames - startFrame, output.count / channels)
        let table = floatSamples
        var frame = 0
        while frame < count {
            let value = table[startFrame + frame]
            var channel = 0
            while channel < channels {
                output[frame * channels + channel] = value
                channel += 1
            }
            frame += 1
        }
        return count
    }
}
