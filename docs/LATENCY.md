# Latency and validation

Physical validation status: **needs-review**, deferred by the user on 2026-09-29
because measurement equipment is unavailable. Synthetic tool tests remain
validated; no real latency result or target pass is inferred.

All numbers here are **provisional engineering goals**, not measurements or guarantees. Reference hardware and measurement uncertainty must be established before any
target becomes a release gate.

## Measure the user experience and the pipeline separately

| Metric | Definition | Use |
| --- | --- | --- |
| Playback mirroring lag | Arrival of a matching audio feature at the phone output minus its arrival at the PC reference output, captured on one timebase | The delay the user notices relative to the computer |
| Capture-to-output delay | Captured-sample timestamp reported by the host API to physical phone output for matching samples | Engineering analysis; requires a calibrated timing bridge |
| Microphone return delay | Physical input/reference event at the phone to matching samples available from the Windows virtual recording endpoint | Full input path, including endpoint buffers |
| Engine-stage delay | Time spent at named capture, encode, queue, decode, and render boundaries | Find avoidable internal delay |
| Network RTT | Round trip on the selected media path | Network diagnostic, not one-way or audible latency |
| Startup / recovery time | User action or interruption to fresh, stable audio | Report separately from steady-state latency |

Computer physical output has its own buffering. Mirroring lag is therefore a relative measurement and can even be negative on some reference paths. Do not silently label it total one-way delay. Report the PC reference device and its configuration.

Timestamps from different monotonic clocks cannot simply be subtracted. Use a shared measurement timebase or a validated clock-offset method with uncertainty bounds. `RTT / 2` is only a symmetry assumption; it is not a measured one-way delay. Device timestamps also do not necessarily reveal delay inside Bluetooth headphones.

## Initial targets

Reference condition: one Windows host connected by Ethernet, one Android phone on an uncongested local access point, direct media, stable routes, no deliberate loss, and a documented wired/USB or calibrated speaker output. Bluetooth is measured separately.

| Test | Proposed goal | Interpretation |
| --- | --- | --- |
| LAN playback mirroring lag | Median ≤ 50 ms; p95 ≤ 80 ms | Relative to the documented PC reference output; report calibration/uncertainty |
| LAN built-in/wired microphone return | Median ≤ 60 ms; p95 ≤ 100 ms | To samples exposed by the Windows input endpoint; consuming app adds its own delay |
| Clean-LAN continuity | No unexplained interruption > 100 ms during a 30-minute run | Count shorter discontinuities and concealed samples too |
| Long-session stability | No unbounded queue or latency growth over 2 hours | Report windowed latency and clock correction, not just start/end averages |
| Already-paired LAN startup | ≤ 3 seconds to usable audio | Excludes first pairing, permission prompts, and Bluetooth route activation |
| Recovery after the path becomes usable | ≤ 5 seconds for the tested network-change scenario | Fresh samples only; measure route/profile changes separately |
| Bluetooth and remote operation | Characterize by route/device/network; no universal bound | Show both the measured total and any separately validated engine contribution |

Run each latency case at least three times and report median, p95, p99, maximum, sample count, uncertainty, and dropout count. Do not claim a target passes if the measurement uncertainty can move it beyond the threshold. If reference devices miss these goals, document the limiting stages before changing the targets.

## Illustrative playback budget

The following is an investigation budget for capture-to-output on a healthy LAN. It is not a measured decomposition of mirroring lag. Terms must have explicit non-overlapping boundaries.

| Stage | Working allowance |
| --- | --- |
| Host capture, adaptation, and scheduling | 5–10 ms |
| Packet formation plus codec work/lookahead | 10–20 ms |
| LAN transit | 1–5 ms |
| Receiver jitter handling | 5–20 ms |
| Decode, native render queue, and non-Bluetooth endpoint | 5–20 ms |
| Illustrative total | 26–75 ms |

Bluetooth endpoint delay, extra OS processing, virtual-cable buffering on the reverse path, and wide-area transit are additional or different stages. A chosen packet duration constrains the budget; measure lookahead and queue residence rather than guessing. The product's speed work should follow measured stage costs.

## Measurement procedure

The runnable [probe and analysis tool](../tools/latency/README.md) implements the
playback correlation step below and is validated against synthetic known offsets.
Compare routes on the working Windows-to-phone path. An uncalibrated estimate by
ear is not a measurement or an established platform limit.

1. Generate a repeatable non-periodic probe or correlation-friendly pulse sequence at a safe level, with speech/music continuity segments between probes.
2. For playback mirroring, record PC reference output and phone output simultaneously on two channels of one audio interface. Prefer electrical connections where possible. If using microphones or a headset coupler, document geometry and account for acoustic propagation and recorder channel skew.
3. Cross-correlate matching windows and preserve the signed lag. Confirm the detector on known artificial offsets before evaluating the product. Do not use a repeated tone that produces ambiguous correlation peaks.
4. For microphone return, record a physical reference and the virtual recording endpoint with an independently validated timing relationship. A calibrated output/capture fixture can establish that relationship; record the residual uncertainty. Rendering the received mic back to a speaker measures an extra output stage and must be labeled accordingly.
5. Capture per-stage telemetry during the same run. Preserve raw numeric observations and analysis settings so percentile results can be reproduced.
6. Repeat with screen off, duplex enabled, and each Bluetooth route. Compare identical network and endpoint conditions when evaluating changes or another product.

Uncalibrated software estimates may guide debugging but cannot establish physical end-to-end targets. Store synthetic benchmark material separately from any user's audio.

## Required telemetry

At roughly one diagnostic update per second, export per direction: effective route/format, codec bitrate and packetization, packet loss/reordering, jitter, jitter-buffer target/actual delay where available, concealed samples, underruns/overruns, queue occupancy, dropped stale audio, clock corrections, reconnect count, selected direct/relay path, and RTT. Also report process CPU/memory and phone battery/thermal state.

Unavailable measurements must say “unavailable.” Never manufacture a single precise end-to-end latency figure from incomplete telemetry. Redact peer addresses and identifiers from shared reports by default.

The current Android snapshot covers selected-path RTT, recent jitter-buffer
means, loss/discard/concealment counters, time stretching, and expected media
route. An output-queue estimate is available where Android APIs support it; this does
not expose physical Bluetooth delay. Route prediction requires API 33; Android 12 reports unavailable.
The snapshot includes phone model/API and build revision but excludes
addresses, SDP, invitations, and serial numbers. Android sends it through the
existing authenticated heartbeat into a combined Windows JSONL session log;
the copy button remains available after a drop. The host receipt and phone
capture clocks are not synchronized and cannot establish one-way delay.
Metrics not available from the platform remain explicitly unavailable; the
full desired telemetry list above is not a promise that every field is implemented. Definitions: [S21–S22](REFERENCES.md).

## Test matrix

| Dimension | Minimum coverage before a public claim |
| --- | --- |
| Audio directions | Listen, microphone only, duplex |
| Output/input routes | Built-in, wired/USB, classic Bluetooth media, Bluetooth headset duplex; LE Audio when available |
| Devices | At least two Android device families and two headset models; record exact models/OS builds |
| Host conditions | Selected/default endpoint changes, 44.1/48 kHz sources, high CPU load, lock, sleep/resume, audio-service restart |
| Network paths | Offline LAN, routed LAN with discovery blocked, direct internet, forced TURN, UDP-blocked fallback, IPv4/IPv6 where supported |
| Impairments | Record direction and distribution; test 0/20/50 ms added one-way delay, 0/5/20 ms jitter, 0/1/3% random loss, bursts, reordering, and bandwidth reduction |
| Phone lifecycle | Screen off, battery saver, foreground/background, call interruption, permission denial/revocation, Wi-Fi/cellular transition |
| Duration | Repeated short measurements, 30-minute continuity, two-hour drift/resource soak |

Impairment combinations should answer a concrete question; not every Cartesian combination is required. Use real devices for routing and audio performance. Emulators are useful for control/UI tests.

## Comparison with SoundWire

Benchmark both products on the same host, phone, output route, access point, and source material. Record SoundWire version and its latency/buffer/compression settings. Compare the lowest stable configurations at a similar quality/dropout level, rather than comparing one tuned configuration with the other's defaults. Keep the measurement method and raw observations in the report.

Until that comparison exists, use “designed for low delay,” not “faster than SoundWire.”
