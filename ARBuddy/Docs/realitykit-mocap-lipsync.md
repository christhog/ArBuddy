# RealityKit Mocap + Lip Sync Checkpoint

Date: 2026-04-26

This checkpoint is the first confirmed Home preview state where Aleda can run a
body idle animation and visible speech lip sync at the same time.

## Confirmed Runtime Signals

Expected logs for the working path:

```text
[BuddyMocap] RealityKit Idle_Standard: playing (loop=true)
[RealityKitPreview] Playing Aleda body-only mocap Idle_Standard on 'Aleda'
[LipSync/RK] Writing RealityKit blend weights to 1 target(s), max=...
```

Do not reintroduce a path that logs bind point failures for the idle clip:

```text
Cannot find a BindPoint
```

## Implementation Notes

- The body idle clip must be an external body-only mocap resource.
- The body clip is played on the cloned Aleda root entity, not directly on the
  `Genesis9` model entity. The animation bind paths include the root hierarchy.
- The external `Idle_Standard.usdz` was regenerated from `Idle-2.fbx` with
  Mixamo `Head` and `Neck` excluded from the retarget mapping, so head/face can
  remain available for speech and later gaze control.
- The body mocap USDZ must not contain face blendshape animation channels.
- Speech lip sync is driven by direct per-frame writes to
  `BlendShapeWeightsComponent`. This avoids competing with the body mocap
  `AnimationResource` on the same RealityKit bind tree.
- Do not call `stopAllAnimations(recursive:)` when speech starts. That stops the
  body idle and caused the previous either-body-or-lips behavior.
- The debug blend-shape pulse was removed because it also stopped animations and
  could mask the real layering behavior.
- `BuddyMocapService` must not silently fall back to embedded Aleda animations
  when an external mocap asset exists but fails to expose a usable animation.
  The embedded Aleda timeline can contain face channels and can override lip
  sync.

## Current Open Item

The lips are visibly moving together with the body animation, but speech timing
is not final yet. Future tuning should focus on the lip sync offset, smoothing,
and viseme-to-shape gain without changing the body/lip layering architecture.
