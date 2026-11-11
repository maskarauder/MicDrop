import tempfile
import unittest
from pathlib import Path
import wave

import numpy as np

import latency


class LatencyTests(unittest.TestCase):
    rate = 8000

    def fixture(self, directory, delay_ms=0, *, invert=False, drop=False, drift=0):
        rng = np.random.default_rng(41)
        reference = np.convolve(rng.standard_normal(self.rate * 12), [0.2, 0.6, 0.2], mode="same") * 0.06
        positions = np.arange(len(reference), dtype=float)
        receiver = np.interp(positions * (1 - drift) - delay_ms * self.rate / 1000,
                             positions, reference, left=0, right=0)
        receiver = receiver * (-0.45 if invert else 0.45) + rng.normal(0, 0.0002, len(reference))
        if drop:
            receiver[self.rate * 5:self.rate * 7] = 0
        path = Path(directory) / "recording.wav"
        with wave.open(str(path), "wb") as wav:
            wav.setnchannels(2); wav.setsampwidth(2); wav.setframerate(self.rate)
            pcm = np.rint(np.column_stack((reference, receiver)) * 32767).astype("<i2")
            wav.writeframes(pcm.tobytes())
        return path

    def test_known_positive_negative_zero_offsets_and_polarity(self):
        for offset in (0, 43.25, 850, -410):
            with self.subTest(offset=offset), tempfile.TemporaryDirectory() as directory:
                result = latency.analyze(self.fixture(directory, offset, invert=True))
                self.assertEqual("usable", result["analysis_status"])
                self.assertAlmostEqual(offset, result["summary"]["median_ms"], delta=0.125)
                self.assertTrue(all(o["polarity"] == -1 for o in result["observations"]))
                self.assertIsNone(result["uncertainty_ms"])

    def test_fixture_skew_is_subtracted_and_settings_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            result = latency.analyze(self.fixture(directory, 125), channel_skew_ms=3, uncertainty_ms=1.5)
            self.assertAlmostEqual(122, result["summary"]["median_ms"], delta=0.125)
            self.assertEqual(1.5, result["uncertainty_ms"])
            self.assertEqual(3, result["settings"]["channel_skew_ms"])

    def test_bad_windows_are_reported_instead_of_biasing_percentiles(self):
        with tempfile.TemporaryDirectory() as directory:
            result = latency.analyze(self.fixture(directory, 100, drop=True))
            self.assertEqual("needs_review", result["analysis_status"])
            self.assertLess(result["windows_accepted"], result["windows_total"])
            self.assertAlmostEqual(100, result["summary"]["median_ms"], delta=0.125)

    def test_silence_periodic_tones_and_clipping_are_not_confident_delays(self):
        length, margin = 800, 400
        zero = latency.estimate(np.zeros(length), np.zeros(length + 2 * margin), self.rate, margin)
        self.assertEqual("reference_silent", zero["status"])
        tone = np.sin(np.arange(length + 2 * margin) * 2 * np.pi * 400 / self.rate) * 0.03
        repeated = latency.estimate(tone[margin:margin + length], tone, self.rate, margin)
        self.assertEqual("ambiguous", repeated["status"])
        clipped = np.sign(np.random.default_rng(3).standard_normal(length + 2 * margin))
        result = latency.estimate(clipped[margin:margin + length], clipped, self.rate, margin)
        self.assertEqual("clipping", result["status"])

    def test_delay_at_search_boundary_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            result = latency.analyze(self.fixture(directory, 100), max_lag_ms=100)
            self.assertEqual(0, result["windows_accepted"])
            self.assertIsNone(result["summary"])

    def test_gradual_drift_remains_visible(self):
        with tempfile.TemporaryDirectory() as directory:
            result = latency.analyze(self.fixture(directory, 120, drift=0.0001))
            self.assertEqual("usable", result["analysis_status"])
            self.assertAlmostEqual(6, result["summary"]["lag_slope_ms_per_minute"], delta=1)

    def test_probe_is_repeatable_quiet_and_exclusive(self):
        first = latency.probe(5, 48000, 12)
        self.assertTrue(np.array_equal(first, latency.probe(5, 48000, 12)))
        self.assertFalse(np.array_equal(first, latency.probe(5, 48000, 13)))
        self.assertLessEqual(np.max(np.abs(first)), 0.03000001)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "probe.wav"
            result = latency.write_probe(path, 5, 48000, 12)
            self.assertEqual(latency.sha256(path), result["sha256"])
            with self.assertRaises(FileExistsError):
                latency.write_probe(path, 5, 48000, 12)

    def test_invalid_channels_and_nonfinite_settings_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.fixture(directory)
            for settings in ({"reference_channel": 2}, {"receiver_channel": 3}, {"max_lag_ms": float("nan")},
                             {"uncertainty_ms": -1}, {"step_ms": 10}):
                with self.subTest(settings=settings), self.assertRaises(ValueError):
                    latency.analyze(path, **settings)


if __name__ == "__main__":
    unittest.main()
