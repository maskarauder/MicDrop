# Benchmark report template

Copy this document for each experiment. This file contains no measured results.

## Run identity

| Field | Value |
| --- | --- |
| Date / operator / report ID | Not recorded |
| Purpose and requirement IDs | Not recorded |
| Commit and build type | Not recorded |
| WebRTC / Oboe / toolchain revisions | Not recorded |
| Compared build or product/version/settings | Not recorded |
| Trial count, duration, warm-up excluded | Not recorded |

## Equipment and environment

| Field | Value |
| --- | --- |
| Host hardware / Windows build / power policy | Not recorded |
| Capture endpoint / format / effects | Not recorded |
| PC physical reference output and buffering | Not recorded |
| Virtual input bridge / version / buffer settings | Not recorded |
| Phone / OS build / app target SDK | Not recorded |
| Requested mode and confirmed input/output routes | Not recorded |
| Headset / Bluetooth profile and codec if observable | Not recorded |
| Native device formats and callback/buffer sizes | Not recorded |
| Audio focus / screen / power / thermal state | Not recorded |
| LAN or WAN topology / direct or TURN / UDP or fallback | Not recorded |
| Network impairment: direction, distribution, parameters | Not recorded |
| Effective media rates, channels, packetization, processing | Not recorded |

## Measurement validity

Describe the timing boundary, fixture, probe, detector, calibration, and uncertainty. For acoustic measurements include distances and channel-skew correction. State whether clocks share a timebase; otherwise explain their alignment and error bound. Document any stages excluded or added by the fixture.

Record raw-data paths and analysis commands. Use synthetic test material; redact network identifiers before sharing. If only estimates are available, label them estimates and leave physical-delay results unavailable.

## Results

| Metric and boundary | Samples | Median | p95 | p99 | Max | Uncertainty |
| --- | --- | --- | --- | --- | --- | --- |
| Playback mirroring lag, ms | — | — | — | — | — | — |
| Calibrated capture-to-output, ms | — | — | — | — | — | — |
| Microphone to virtual input, ms | — | — | — | — | — | — |
| Network RTT, ms | — | — | — | — | — | — |

Report startup/recovery separately. Add each trial's result, not only pooled percentiles. Include dropout durations, concealed-sample rate, underruns/overruns, jitter-buffer residence, queue growth, clock correction, CPU/memory, bandwidth, and battery/thermal observations.

## Interpretation

- Which target passed, failed, or could not be established?
- Which stage or route explains the remaining delay?
- Does a lower buffer setting trade delay for audible damage?
- Did the actual input/output differ from the requested route?
- What changed during the two-hour run?
- What single follow-up experiment would resolve the largest uncertainty?

Record reproduction steps and known limitations. Do not turn an unverified inference into a supported-device claim.
