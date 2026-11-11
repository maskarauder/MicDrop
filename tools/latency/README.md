# Playback mirroring measurement

This developer tool generates a quiet, non-repeating PCM16 measurement WAV and
analyzes a simultaneous recording of PC reference output and phone output. It
measures **receiver arrival minus PC reference arrival**; positive means the
phone is later. It does not measure absolute capture-to-speaker latency, network
one-way delay, or a microphone return path.

## Quick diagnosis without a measurement fixture

In the Android app, stream ordinary desktop audio for at least a minute. Reports
are automatically included in the Windows **Combined session log** at the path
printed by the host. Repeat on the phone speaker, a wired/USB route if available,
and Bluetooth. Select the route in Android's media controls before connecting
and use a fresh Windows invitation each time. Keep each session's log and note
which physical output you heard and any interruptions. Listen for a few minutes
to capture later behavior too. **Copy last stream report** remains a fallback
after a drop or logging failure.

The report includes a snapshot time, build revision, phone model/API level,
expected media route, selected-path RTT, RTP jitter, recent jitter-buffer
actual/target/minimum means, packet counters, concealment, and time stretching.
It excludes invitations, host/peer addresses, SDP, and device serial numbers.
Reports go only to the connected Windows host over the authenticated session.
The default log is `diagnostics-private/micdrop-<time>-<unique>.jsonl`; use
`stream --log <new.jsonl>` for a chosen path or `--no-log` to disable it. Logs are
bounded to 16 MiB per session and stay on the PC until deleted. Existing files
are never overwritten. Copying remains explicit, and no audio is in these logs.

The roughly two-second window uses differences of cumulative counters. The
first sample, missing counters, idle sample denominators, reset counters, and
gaps over ten seconds produce `unavailable`. A net-loss change may be negative
when late packets correct the cumulative estimate. RTT is a round trip, not
audible delay. Buffer statistics exclude downstream phone/headset buffering.

On Android 13+, the route is Android's **prediction** for media/music attributes,
not a confirmed AudioTrack route. On Android 12 that prediction is unavailable.
Listen to confirm the destination. Device names, Bluetooth codecs, the actual
AudioTrack queue, and physical Bluetooth delay are not exposed by this adapter.

If RTT and recent jitter-buffer delay stay low but a large audible gap persists,
investigate downstream output and reference-device buffering. That is a clue,
not a complete measured decomposition. Do not add the displayed figures into a
claimed end-to-end latency number.

## Installation and probe

Requires Python 3.11+ and the pinned NumPy package. In a repository checkout use
`tools/latency`; the Windows build artifact also includes this folder as
`latency-tools`. Run from that directory:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe latency.py generate probe.wav
```

On Linux/macOS use `.venv/bin/python`. The default is 24 seconds of deterministic
300–6000 Hz noise at 48 kHz, duplicated to both channels, with a maximum digital
peak of 0.03 and faded ends. Start with low playback/recording levels. This file
contains generated audio only. `--seconds`, `--sample-rate` (44100/48000), and
`--seed` are recorded alongside its SHA-256 in the command's JSON output. Save
that output with the benchmark notes. Existing output files are never replaced.

Play this WAV once through the Windows endpoint being captured, using an audio
player, while MicDrop streams **live desktop output**. Do not use `stream
--probe` for timing: that is a periodic stereo tone for checking routing.

## One recorder, two isolated channels

1. Record the PC reference output into channel 1 and the phone/headphone output
   into channel 2 of **the same audio interface/recorder**. Use suitable line
   connections or separate microphones/couplers. Keep signals isolated; one
   microphone hearing both outputs can create ambiguous peaks or a false zero
   lag. Do not connect amplified speaker terminals to line inputs.
2. First feed the same signal into both recording paths to measure channel skew.
   Positive skew means the channel-2 fixture arrives later. Document the fixture,
   reference headset/device, distances, rate, and remaining timing uncertainty.
   Include acoustic path differences in the calibration. Record without AGC,
   noise suppression, time stretching, or separate per-channel edits.
3. Warm up the live stream, record the complete probe, and export one ordinary
   interleaved **16-bit PCM WAV**, with both channels on their original timebase.
   Separate recordings and independently aligned tracks do not qualify. The
   tool cannot verify that the physical fixture satisfies these conditions.
4. Repeat at least three times on each route. Keep source, levels, reference
   output, and network fixed when comparing routes, builds, or SoundWire.

## Analysis

```powershell
.\.venv\Scripts\python.exe latency.py analyze simultaneous.wav --output result.json
```

Defaults: reference channel 1, receiver channel 2, signed search ±1500 ms,
800 ms windows at 1000 ms steps, first two seconds excluded. Windows without a
complete search range at either file edge are also excluded. Controls include
`--max-lag-ms`, `--window-ms`, `--step-ms`, `--warmup-s`, `--reference-channel`, and
`--receiver-channel`. Steps must be at least as long as the window.

Supply measured `--channel-skew-ms` to subtract the fixture's channel-2 offset.
Supply `--uncertainty-ms` only when you have established it; the default remains
unavailable. For example, if independently measured skew is +1.2 ms and total
uncertainty is 2 ms, add `--channel-skew-ms 1.2 --uncertainty-ms 2`.

The JSON contains every detection, signed raw/corrected lag, normalized
correlation and competing-peak score, rejected windows, median/p95/p99/min/max,
and a linear lag trend in ms/minute when at least three windows pass. That trend
does not by itself identify clock drift. Percentiles use NumPy's default linear
interpolation and summarize accepted windows, not every packet or audio sample.

Silence, weak correlation, periodic/ambiguous peaks, clipping above 0.1%, and a
peak at the search boundary are rejected. Rejections remain visible and make
the result `needs_review`; they are not counted as delays or dropout durations.
At least three accepted windows and no rejected windows are needed for
`usable`. This means the detector found consistent usable matches, not that a
latency target or fixture calibration passed. Inspect the waveforms/fixture
when rejections occur; do not lower `--min-correlation` just to obtain a number.

Exit codes: 0 = usable/generation succeeded; 1 = report written but needs review;
2 = invalid input or I/O failure. Output JSON is never overwritten. Inputs are
bounded to five minutes, 2–8 channels, and 8–192 kHz. Sample-grid resolution is
reported separately from physical uncertainty. No user recording is uploaded.

## Validation and limits

Run `python -m unittest discover -s . -p 'test_*.py' -v`. Tests cover known
positive/negative/zero offsets, gain/polarity/noise, fixture skew, gradual drift,
missing audio, silence, repeated tones, clipping, boundary detection, invalid
inputs, and probe reproducibility. Synthetic correctness does not validate a
real acoustic fixture, codec/route compatibility, or an end-to-end target.

Reference definitions: [WebRTC statistics](https://www.w3.org/TR/webrtc-stats/),
[Android route prediction](https://developer.android.com/reference/android/media/AudioManager#getAudioDevicesForAttributes(android.media.AudioAttributes)),
and [NumPy correlation](https://numpy.org/doc/stable/reference/generated/numpy.correlate.html).
