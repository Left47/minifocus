# First-pass foreground tracking validation

The tracker now has a fast path for miniatures with paint colors that can be separated from the surrounding hand, handle and scene. It tracks visible painted regions rather than requiring an upright silhouette. Neutral-only or otherwise indistinct targets retain the existing image-identity fallback.

## Behavior

- Learn target paint and negative color samples from the selected region, its surrounding ring, and the full scene. A face is not required.
- Exclude unchanged background locations outside the initial target, including similarly colored shelf objects.
- Treat the background behind the initial selection as unknown. This allows a mini to return to exactly the same location after a covering hand or brush moves away.
- Track coherent visible painted regions through rotation and partial obstruction. The focus box may shrink to an exposed part of the mini.
- Hold focus during complete obstruction or absence. Confirm the target across frames before resuming; do not switch between two equally plausible separated candidates.
- Prefer the current target's location when another similar foreground object enters.
- Keep tracking during later focus adjustments instead of freezing the box whenever the lens searches.

## Checks run

The automated suite has 152 checks, including hand-in-selection learning with no face, a moving hand alone, partial finger/brush obstruction, full covering and uncovering, a thin same-colored brush, a dark painting handle, an unchanged similar-colored shelf object, ambiguous targets, and return after a long absence. Native Vision rotation/background tests still cover the fallback.

An existing local recording was replayed offline. Nine manually reviewed checkpoints passed: upright, steady, tilted, sideways, sideways held, upside down, absent, returned elsewhere, and returned held. A positive checkpoint requires the focus-region center inside the annotated miniature, at least 65% of that focus region on the annotated target, and a region at least 10% of the annotated target area. This permits a useful focus patch on a visible limb or painted cloth rather than requiring a whole-object bounding box. The absent checkpoint requires no accepted target.

Foreground tracking measured approximately 0.9 ms p95 and 1.5 ms maximum in that replay. This times the foreground detector and temporal confirmation only; it excludes decoding, preview rendering, focus hardware, and recording. It must not be compared directly with end-to-end camera-callback timing or treated as a new OBS recording test.

The video and its annotations stay local and are not included in this repository. The checked clip informed this first pass; a new representative setup is needed for independent validation.

## Run an offline replay

```sh
bash scripts/replay.sh /path/to/existing-video.mp4 /path/to/labels.json build/replay-results.json
```

The command decodes an existing video and runs the same foreground tracker used by the application. It does not open a camera, write focus controls, or start recording.

Labels contain a normalized lower-left-origin `seed` box and checkpoints:

```json
{
  "seed": [0.3, 0.35, 0.2, 0.3],
  "checks": [
    {"time": 1.0, "name": "visible", "rect": [0.3, 0.35, 0.2, 0.3]},
    {"time": 5.0, "name": "absent"}
  ]
}
```

## Remaining work

This remains appearance tracking rather than a trained miniature detector. Matching colored equipment, a new paint scheme, an edge-on view with very little visible paint, camera movement, lighting changes, and neutral primed minis need further practical checks. Keep the camera mounted after selection, or draw a new box to rebuild the scene reference.

The next live test should use a representative painting setup with hands, handles, brushes, partial/full occlusion, rotation, and exits/returns. Confirm readiness before starting any recording. [Issue #1](https://github.com/Left47/minifocus/issues/1) remains open until practical acceptance checks pass.
