# MiniFocus

A native macOS companion for keeping a painted miniature in focus while OBS records a Logitech C930e.

MiniFocus analyzes a region you select in a live preview and adjusts the camera's physical lens over USB. OBS continues to capture the camera directly. No OBS plugin, virtual camera, Python runtime, or third-party packages are required.

This is an early prototype. Expect visible focus checks and several seconds of hunting during initial acquisition. It cannot overcome the lens's minimum focusing distance or guarantee correct tracking through a hand, brush, or another object.

## Requirements

- macOS 13 or later.
- One Logitech C930e (`046d:0843`). Other cameras, including EMEET models, are not enabled in this version.
- Xcode or the Xcode Command Line Tools to build.
- Camera permission for MiniFocus.

## Build and run

```sh
bash scripts/build.sh
open build/MiniFocus.app
```

The build script creates a locally ad-hoc-signed app for your Mac's architecture. It is not notarized or signed with a distribution certificate. Building locally is the supported installation method for this prototype.

## Painting workflow

1. Open MiniFocus and click **Connect**. Grant camera permission if prompted.
2. Draw a tight box around the miniature, excluding the base, fingers, palette, and background where possible.
3. **Keep the miniature inside the fixed box during the initial focus search.** Selection automatically acquires focus. A quick search probes around the current lens position, expands toward improving sharpness, refines the best position, then starts tracking from the focused image. Nearby focus typically needs fewer probes than a full-range scan.
4. In OBS, add or select a **Video Capture Device** source and choose **Logitech Webcam C930e**. Use 1920×1080 where available. Leave native autofocus off and close competing camera-settings applications.
5. Leave MiniFocus open while recording. Once acquisition completes, move the miniature gradually; local focus checks follow smaller distance changes. If quick acquisition misses, use **Reacquire** for a slower full-range scan and hold the miniature inside the box again.

**Hold** pauses lens changes at the last settled focus. **Start following** resumes local checks. **Stop & restore**, reconnecting, and normal app quit restore the focus and autofocus settings captured when you connected. A crash, force quit, or unplug can prevent restoration; use your camera settings app if necessary.

If tracking becomes uncertain or the miniature leaves the frame, the app holds the last settled lens position and keeps looking. Recovery checks nearby positions and scales, then searches across the whole frame using several remembered views of the miniature. Apple's Vision feature prints compare proposed matches with the selected miniature and sampled background regions; a candidate must resemble the miniature more closely than the background and remain consistent across two observations before focus changes resume. A recovered target triggers quick focus acquisition. No new box is needed for an ordinary exit and return; draw a new one to change targets or replace the learned reference. This is image matching rather than a trained miniature detector; an unseen pose, severe blur, or similar-looking object can still defeat recovery.

Uncheck **Track miniature movement** to use a fixed focus region. This can be useful if you keep the mini in one part of the frame or tracking struggles with its appearance.

**Search limits** restrict allowed lens positions, in camera units rather than physical distance. The C930e tested here reports 0–255 in increments of 5. Limits take effect when you click Start following or Reacquire; a new selection uses the most recently applied limits. Narrowing them to your painting range reduces acquisition time and background searches.

## OBS compatibility

Both applications need access to the same camera frames. Simultaneous live preview and an 86.1-second coordinated 1080p/60 OBS recording were verified on the development Mac, with no additional OBS rendering misses or encoding skips. Recovery processing was slower and target identity still failed during rotation; see [the performance results](PERFORMANCE.md). MiniFocus never seizes the USB interface from the camera driver. If either app shows no video, stop following, reconnect, and check camera permissions and matching capture settings.

MiniFocus's selection overlay is displayed only in its preview. It is not added to OBS's direct camera feed. Do not use window capture of MiniFocus as your recording source unless you want its controls and overlay in the recording.

## How focus works

- Apple's Vision object tracker updates the selected region, with confidence, motion, size, frame-boundary, and appearance checks. Color histograms and luminance correlation propose matches at multiple roll angles; Vision feature-print references include 15-degree rotation increments. Confirmed new views can update the remembered appearances while background references continue to reject unrelated candidates. Local multiscale matching handles size changes; persistent whole-frame re-identification handles exits and returns. This is not a trained miniature detector, and reliable arbitrary three-dimensional rotation remains unfinished.
- Initial acquisition holds the selected region fixed, avoiding tracking failures caused by deliberate defocus during the lens sweep. Tracking starts after the final lens position has settled.
- The app computes luminance Laplacian variance inside the central 76% of the target, so surrounding desktop detail has less influence.
- Focus search waits for lens settling and takes the median of three samples per position. Selection uses an expanding local bracket followed by finer sampling; Reacquire uses a full coarse scan and refinement. Following uses local probes with an improvement threshold to reduce drift.
- USB writes are range-checked and read back. Camera interruptions and external focus changes stop following.
- Preview and tracking run at approximately 10 fps, with faster sharpness sampling during acquisition; the capture session requests 1080p. OBS's own capture and recording settings remain separate.

All image processing happens locally. The app has no networking, recording, microphone capture, or image-upload features.

## Verification

```sh
# Deterministic algorithm tests; no camera required
bash scripts/test.sh

# Also briefly change the attached C930e's focus and restore it
bash scripts/test.sh --hardware

# Exercise native Vision identity learning and background rejection without a camera
bash scripts/test.sh --vision

# Launch with console diagnostics for live frames and USB reads
build/MiniFocus.app/Contents/MacOS/MiniFocus --diagnose

# Also retain local performance counters without recording camera images
build/MiniFocus.app/Contents/MacOS/MiniFocus --diagnose --performance-log "$PWD/build/performance-session.jsonl"
```

Hardware tests intentionally move focus one increment and restore the original settings. Run them with MiniFocus stopped so two controllers do not compete.

The Mac tests passed 130 algorithm checks and native Vision identity checks at 7°, 17°, 45°, 90°, 137°, 180°, 225°, 270°, and 345°, with background rejection checked at every angle. Hardware focus write/readback/restoration also passed. A synthetic nearby-focus case needed 8 lens probes for quick acquisition versus 19 for the full scan. The coordinated OBS recording check passed without new rendering/encoding misses; real miniature rotation and recovery still lost the target. See [PERFORMANCE.md](PERFORMANCE.md) and [issue #1](https://github.com/Left47/minifocus/issues/1) for the evidence and remaining work. No camera images or recordings are included in this repository.

## Layout

- `Sources/App.swift`: AppKit window, preview, region selection, and controls.
- `Sources/CameraEngine.swift`: camera frames, tracking, focus workflow, and restoration.
- `Sources/FocusLogic.swift`: geometry, sharpness measurement, and focus search.
- `Sources/FramePerformance.swift`: bounded processing-time samples and capture-delivery counters.
- `Sources/TargetAppearance.swift`: appearance checks and multiscale recovery.
- `Sources/VisionIdentity.swift`: learned target/background image similarity verification.
- `Sources/FocusUSB.c`: C930e USB camera-terminal controls through IOKit.
- `Tests/`: deterministic focus logic tests and opt-in physical camera checks.
- `focus_probe.c`: standalone focus probe used during the initial hardware investigation.

## License

MIT. See [LICENSE](LICENSE).
