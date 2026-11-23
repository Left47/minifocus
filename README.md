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
3. **Keep the miniature inside the fixed box during the initial focus search.** Selection automatically acquires focus. The lens scans the allowed range, refines around the sharpest position, then starts tracking from the focused image. A full-range search can take approximately 10–20 seconds.
4. In OBS, add or select a **Video Capture Device** source and choose **Logitech Webcam C930e**. Use 1920×1080 where available. Leave native autofocus off and close competing camera-settings applications.
5. Leave MiniFocus open while recording. Once acquisition completes, move the miniature gradually; local focus checks follow smaller distance changes. Use **Reacquire** for a large distance change and hold the miniature inside the box again.

**Hold** pauses lens changes at the last settled focus. **Start following** resumes local checks. **Stop & restore**, reconnecting, and normal app quit restore the focus and autofocus settings captured when you connected. A crash, force quit, or unplug can prevent restoration; use your camera settings app if necessary.

If tracking becomes uncertain, the app stops following and returns to the last settled lens position. Draw a new box to acquire again. The tracker follows visual appearance; it does not recognize miniatures semantically, and some occlusions may escape the confidence checks.

Uncheck **Track miniature movement** to use a fixed focus region. This can be useful if you keep the mini in one part of the frame or tracking struggles with its appearance.

**Search limits** restrict allowed lens positions, in camera units rather than physical distance. The C930e tested here reports 0–255 in increments of 5. Limits take effect when you click Start following or Reacquire; a new selection uses the most recently applied limits. Narrowing them to your painting range reduces acquisition time and background searches.

## OBS compatibility

Both applications need access to the same camera frames. Direct simultaneous live preview was verified with MiniFocus and OBS on the development Mac. The recording test was blocked by an unavailable recording destination in OBS; recording verification remains outstanding. MiniFocus never seizes the USB interface from the camera driver. If either app shows no video, stop following, reconnect, and check camera permissions and matching capture settings. A future frame-sharing or OBS integration may be needed on systems where concurrent capture is unavailable.

MiniFocus's selection overlay is displayed only in its preview. It is not added to OBS's direct camera feed. Do not use window capture of MiniFocus as your recording source unless you want its controls and overlay in the recording.

## How focus works

- Apple's Vision object tracker updates the selected region, with confidence, motion, size, and frame-boundary checks.
- Initial acquisition holds the selected region fixed, avoiding tracking failures caused by deliberate defocus during the lens sweep. Tracking starts after the final lens position has settled.
- The app computes luminance Laplacian variance inside the central 76% of the target, so surrounding desktop detail has less influence.
- Focus search waits for lens settling and takes the median of three samples per position. Initial acquisition uses a coarse scan followed by finer sampling. Following uses local probes with an improvement threshold to reduce drift.
- USB writes are range-checked and read back. Camera interruptions and external focus changes stop following.
- Preview and analysis run at approximately 10 fps; the capture session requests 1080p. OBS's own capture and recording settings remain separate.

All image processing happens locally. The app has no networking, recording, microphone capture, or image-upload features.

## Verification

```sh
# Deterministic algorithm tests; no camera required
bash scripts/test.sh

# Also briefly change the attached C930e's focus and restore it
bash scripts/test.sh --hardware

# Launch with console diagnostics for live frames and USB reads
build/MiniFocus.app/Contents/MacOS/MiniFocus --diagnose
```

Hardware tests intentionally move focus one increment and restore the original settings. Run them with MiniFocus stopped so two controllers do not compete.

The Mac tests passed 86 algorithm checks, USB focus write/readback/restore, and live 1920×1080 preview with USB access still available. Initial acquisition now defers tracking through the sweep and final settling, with regression coverage for that behavior. Concurrent OBS preview and the app's transition into following mode were observed; optical performance across painting distances and OBS recording verification are still under evaluation. No camera images or recordings are included in this repository.

## Layout

- `Sources/App.swift`: AppKit window, preview, region selection, and controls.
- `Sources/CameraEngine.swift`: camera frames, tracking, focus workflow, and restoration.
- `Sources/FocusLogic.swift`: geometry, sharpness measurement, and focus search.
- `Sources/FocusUSB.c`: C930e USB camera-terminal controls through IOKit.
- `Tests/`: deterministic focus logic tests and opt-in physical camera checks.
- `focus_probe.c`: standalone focus probe used during the initial hardware investigation.

## License

MIT. See [LICENSE](LICENSE).
