"""Generate a synthetic probe; measure relative lag in a shared-clock PCM16 WAV.

No audio capture, networking, or playback occurs here. See README.md for the
two-channel fixture. Positive lag means the receiver output arrived later.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import wave

import numpy as np

VERSION = 1


def probe(seconds=24, sample_rate=48000, seed=1):
    """Non-repeating, deterministic, band-limited noise; 0.03 peak maximum."""
    if not 5 <= seconds <= 120 or sample_rate not in (44100, 48000):
        raise ValueError("Probe duration must be 5–120 s; rate must be 44100 or 48000 Hz")
    size = round(seconds * sample_rate)
    rng = np.random.Generator(np.random.PCG64(seed))
    spectrum = np.fft.rfft(rng.standard_normal(size))
    frequencies = np.fft.rfftfreq(size, 1 / sample_rate)
    spectrum[(frequencies < 300) | (frequencies > 6000)] = 0
    samples = np.fft.irfft(spectrum, n=size)
    fade = min(round(0.05 * sample_rate), size // 2)
    ramp = np.sin(np.linspace(0, np.pi / 2, fade)) ** 2
    samples[:fade] *= ramp
    samples[-fade:] *= ramp[::-1]
    return samples * (0.03 / np.max(np.abs(samples)))


def write_probe(path, seconds=24, sample_rate=48000, seed=1):
    signal = probe(seconds, sample_rate, seed)
    pcm = np.repeat(np.rint(signal * 32767).astype("<i2")[:, None], 2, axis=1)
    # Exclusive create: measurement recordings must never be overwritten.
    with open(path, "xb") as output:
        with wave.open(output, "wb") as wav:
            wav.setnchannels(2)
            wav.setsampwidth(2)
            wav.setframerate(sample_rate)
            wav.writeframes(pcm.tobytes())
    return {"probe_version": VERSION, "seed": seed, "sample_rate_hz": sample_rate,
            "seconds": seconds, "peak_limit": 0.03, "sha256": sha256(path)}


def sha256(path):
    with open(path, "rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def estimate(reference, search, sample_rate, max_lag, min_correlation=0.5):
    """Normalized valid cross-correlation using equal-length overlapping data.

    search starts max_lag samples before reference, so index max_lag is zero
    relative delay. FFT is zero-padded to produce linear, not circular, lags.
    """
    if len(search) != len(reference) + 2 * max_lag or max_lag < 1:
        raise ValueError("Invalid correlation window")
    if not np.isfinite(reference).all() or not np.isfinite(search).all():
        return {"status": "nonfinite"}
    reference = reference.astype(np.float64)
    search = search.astype(np.float64)
    centered = reference - reference.mean()
    energy = float(np.dot(centered, centered))
    if energy / len(reference) < 1e-7:  # Below approximately -70 dBFS RMS.
        return {"status": "reference_silent"}
    size = len(reference)
    fft_size = 1 << (len(search) + size - 2).bit_length()
    dots = np.fft.irfft(np.fft.rfft(search, fft_size) *
                        np.conj(np.fft.rfft(centered, fft_size)), fft_size)[:2 * max_lag + 1]
    sums = np.concatenate(([0.0], np.cumsum(search)))
    squares = np.concatenate(([0.0], np.cumsum(search * search)))
    variance = squares[size:] - squares[:-size] - (sums[size:] - sums[:-size]) ** 2 / size
    valid = variance / size >= 1e-7
    correlation = np.zeros(len(dots))
    correlation[valid] = dots[valid] / np.sqrt(energy * np.maximum(variance[valid], 0))
    scores = np.minimum(1.0, np.abs(correlation))
    peak = int(np.argmax(scores))
    # Ignore the main peak's nearby filter lobes; repeated tones and strong
    # separated echoes must not produce a confident arbitrary lag.
    exclusion = max(1, round(0.002 * sample_rate))
    rivals = scores.copy()
    rivals[max(0, peak - exclusion):peak + exclusion + 1] = 0
    runner_up = float(np.max(rivals))
    result = {"correlation": float(scores[peak]), "runner_up": runner_up,
              "polarity": -1 if correlation[peak] < 0 else 1}
    if scores[peak] < min_correlation:
        return dict(result, status="weak_match")
    if runner_up >= 0.9 * scores[peak]:
        return dict(result, status="ambiguous")
    if peak in (0, 2 * max_lag):
        return dict(result, status="search_boundary")
    receiver = search[peak:peak + size]
    clipping = max(float(np.mean(np.abs(reference) >= 32767 / 32768)),
                   float(np.mean(np.abs(receiver) >= 32767 / 32768)))
    if clipping > 0.001:
        return dict(result, status="clipping", clipped_fraction=clipping)
    return dict(result, status="accepted", lag_samples=peak - max_lag,
                raw_lag_ms=1000 * (peak - max_lag) / sample_rate)


def analyze(path, reference_channel=1, receiver_channel=2, max_lag_ms=1500,
            window_ms=800, step_ms=1000, warmup_s=2, channel_skew_ms=0,
            uncertainty_ms=None, min_correlation=0.5):
    numeric = [max_lag_ms, window_ms, step_ms, warmup_s, channel_skew_ms, min_correlation]
    if not all(math.isfinite(v) for v in numeric):
        raise ValueError("Analysis settings must be finite")
    if not (10 <= max_lag_ms <= 5000 and 100 <= window_ms <= 5000 and
            window_ms <= step_ms <= 10000 and 0 <= warmup_s <= 120 and
            abs(channel_skew_ms) <= 5000 and 0.1 <= min_correlation <= 1):
        raise ValueError("Invalid analysis bounds; step must be at least the window length")
    if uncertainty_ms is not None and (not math.isfinite(uncertainty_ms) or uncertainty_ms < 0):
        raise ValueError("Uncertainty must be nonnegative and finite")
    observations = []
    with wave.open(str(path), "rb") as wav:
        rate, channels, frames = wav.getframerate(), wav.getnchannels(), wav.getnframes()
        if wav.getsampwidth() != 2 or wav.getcomptype() != "NONE":
            raise ValueError("Export an uncompressed 16-bit PCM WAV")
        if not (8000 <= rate <= 192000 and 2 <= channels <= 8 and 0 < frames / rate <= 300):
            raise ValueError("Use a 2–8 channel, 8–192 kHz recording no longer than five minutes")
        if reference_channel == receiver_channel or not all(1 <= c <= channels for c in (reference_channel, receiver_channel)):
            raise ValueError("Reference and receiver must be different existing channels (1-based)")
        width, margin, step = (round(ms * rate / 1000) for ms in (window_ms, max_lag_ms, step_ms))
        start = max(round(warmup_s * rate), margin)
        # Read only one bounded search window at a time, even for long WAVs.
        while start + width + margin <= frames:
            wav.setpos(start - margin)
            count = width + 2 * margin
            raw = wav.readframes(count)
            if len(raw) != count * channels * 2:
                raise ValueError("Truncated recording")
            samples = np.frombuffer(raw, dtype="<i2").reshape(-1, channels).astype(np.float64) / 32768
            reference = samples[margin:margin + width, reference_channel - 1]
            search = samples[:, receiver_channel - 1]
            result = estimate(reference, search, rate, margin, min_correlation)
            result["reference_time_s"] = start / rate
            if result["status"] == "accepted":
                result["lag_ms"] = result["raw_lag_ms"] - channel_skew_ms
            observations.append(result)
            start += step
    if not observations:
        raise ValueError("Recording too short for warm-up, window, and signed lag search")
    accepted = [o for o in observations if o["status"] == "accepted"]
    delays = np.array([o["lag_ms"] for o in accepted])
    summary = None
    if accepted:
        summary = {key: float(value) for key, value in zip(
            ("minimum_ms", "median_ms", "p95_ms", "p99_ms", "maximum_ms"),
            np.percentile(delays, [0, 50, 95, 99, 100]))}
        if len(accepted) >= 3:
            times = np.array([o["reference_time_s"] for o in accepted])
            times -= times.mean()
            summary["lag_slope_ms_per_minute"] = float(60 * np.dot(times, delays - delays.mean()) / np.dot(times, times))
    return {
        "analysis_version": VERSION, "numpy_version": np.__version__, "recording_sha256": sha256(path),
        "metric": "receiver physical output minus PC reference output on one recorder timebase",
        "positive_lag": "receiver later", "sample_rate_hz": rate, "recording_channels": channels,
        "recording_seconds": frames / rate, "sample_grid_ms": 1000 / rate,
        "uncertainty_ms": uncertainty_ms, "uncertainty_source": "operator supplied" if uncertainty_ms is not None else "unavailable",
        "settings": {"reference_channel": reference_channel, "receiver_channel": receiver_channel,
            "max_lag_ms": max_lag_ms, "window_ms": window_ms, "step_ms": step_ms,
            "warmup_s": warmup_s, "channel_skew_ms": channel_skew_ms, "min_correlation": min_correlation},
        "windows_total": len(observations), "windows_accepted": len(accepted),
        "analysis_status": "usable" if len(accepted) >= 3 and len(accepted) == len(observations) else "needs_review",
        "summary": summary, "observations": observations,
        "limitations": ["Fixture calibration and acoustic geometry are operator responsibilities.",
            "Sample-grid resolution is not total measurement uncertainty.",
            "Rejected windows are not counted as measured delays or dropout durations.",
            "Window percentiles describe this recording, not per-packet latency or a release target."],
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    generator = commands.add_parser("generate", help="Write a quiet synthetic measurement WAV")
    generator.add_argument("output", type=Path)
    generator.add_argument("--seconds", type=float, default=24)
    generator.add_argument("--sample-rate", type=int, default=48000)
    generator.add_argument("--seed", type=int, default=1)
    analyzer = commands.add_parser("analyze", help="Analyze simultaneous reference/receiver channels")
    analyzer.add_argument("recording", type=Path)
    analyzer.add_argument("--output", type=Path)
    analyzer.add_argument("--reference-channel", type=int, default=1)
    analyzer.add_argument("--receiver-channel", type=int, default=2)
    for name, default in [("max-lag-ms", 1500), ("window-ms", 800), ("step-ms", 1000),
                          ("warmup-s", 2), ("channel-skew-ms", 0), ("min-correlation", 0.5)]:
        analyzer.add_argument("--" + name, type=float, default=default)
    analyzer.add_argument("--uncertainty-ms", type=float)
    args = vars(parser.parse_args(argv))
    command = args.pop("command")
    try:
        if command == "generate":
            result = write_probe(args.pop("output"), **args)
            output = None
        else:
            output = args.pop("output")
            result = analyze(args.pop("recording"), **args)
        rendered = json.dumps(result, indent=2, allow_nan=False) + "\n"
        if output is not None:
            with output.open("x", encoding="utf-8") as target:
                target.write(rendered)
        else:
            print(rendered, end="")
        return 0 if result.get("analysis_status", "usable") == "usable" else 1
    except (OSError, ValueError, wave.Error, EOFError) as error:
        parser.exit(2, f"latency: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
