# Recording performance check — 2026-11-23

The coordinated movement recording showed no additional OBS rendering misses and no encoding skips. Recovery still lagged and failed to maintain the miniature's identity reliably. Recording performance and tracking correctness must therefore be evaluated separately.

## Setup and procedure

- Logitech C930e on the development Mac, captured directly by OBS and MiniFocus.
- OBS 33.0.3, 1920×1080 output at 60 fps, Apple hardware HEVC encoding; camera-source buffering disabled.
- A 20.6-second OBS-only baseline with MiniFocus closed.
- An 86.1-second recording after explicit readiness confirmation, with separate cues for steady tracking, rotation including upside down, and exiting/returning to the frame.
- Local controller timing logs, OBS Stats, full video decoding, presentation-timestamp inspection, and freeze detection. No recording or camera images are published here.

## Recording results

| Check | Observation |
| --- | --- |
| Saved movement recording | 1920×1080 HEVC, 60 fps, 5,166 decoded frames, 86.1 seconds |
| OBS encoding skips | 0 / 5,176 frames in the final Stats display |
| Additional OBS rendering misses | 0; the existing cumulative count of 4 remained unchanged |
| OBS final average render time | 2.4 ms |
| Interior video timestamp gaps | None above 25 ms; normal intervals approximately 16.67 ms |
| Terminal timestamp gap | Both baseline and movement files have the same approximately 66.67 ms final-packet gap |
| Video freeze check | No interval of at least 0.5 seconds detected at a −60 dB pixel-difference threshold |
| Controller-reported capture-drop callbacks | No increase during the coordinated test |

Four cumulative rendering misses had already been observed before the coordinated test. They are not evidence of drops caused by the rotation or recovery portion. Earlier unattended footage was not used to validate physical rotation/recovery behavior.

These are short local recording results, not an Internet-streaming or long-session guarantee. A 60 fps recording also does not mean the webcam supplies 60 distinct images per second.

## Controller results and limitations

Recent timing windows showed following at roughly 9 ms median and 43 ms p95. Recovery was considerably more expensive: roughly 196–228 ms p95, with an observed maximum of 241 ms. The initial identity-learning acquisition had a 318 ms processing spike. These are per-analysis-frame processing times, not end-to-end video latency; the log stores bounded rolling samples for each mode.

Delivered camera callbacks were approximately 24 fps during steady tracking and fell to about 21 fps over the movement portion. No drop callbacks were reported, so that counter alone must not be treated as proof of uninterrupted analysis delivery. Recovery work can delay the controller even when OBS's separate video path remains smooth.

The real rotation test still caused the target to be lost, and recovery was not consistently correct. Synthetic rotated-image checks pass, but they do not establish reliable tracking when a three-dimensional miniature exposes a different side or is partly hidden by fingers. These acceptance checks remain open in [issue #1](https://github.com/Left47/minifocus/issues/1).

## Repeating the test

Always confirm the participant is ready before starting recording, then cue the phases individually. Preserve the existing OBS profile and camera settings.

```sh
bash scripts/build.sh
build/MiniFocus.app/Contents/MacOS/MiniFocus --diagnose --performance-log "$PWD/build/performance-session.jsonl"
```

The on-screen line reports delivery FPS, analysis p95, and explicit drop notifications. JSONL output adds per-mode medians, p95, maximum time, and timestamps. Deliberately throttled analysis frames are separate from framework-reported capture drops. Compare OBS's rendering/encoding counters before and after recording, and inspect the saved file rather than relying on the preview alone.
