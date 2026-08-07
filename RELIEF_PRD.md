# Relief PRD

Mac app that converts any 2D video into an Apple spatial video (MV-HEVC) for Vision Pro.

Named for relief sculpture: depth raised from a flat surface. That is the whole product.

## User

Russell. One user. A Vision Pro owner with a library of flat movies and clips, sitting down in the evening wanting to watch something in 3D. Today he either hunts for the small pool of native spatial content or watches flat. VITURE solved this for their glasses; nothing he owns solves it for his.

## Moment of friction

He queues up a favorite film on the Vision Pro, remembers the theater-scale screen would sing in stereo, and has no way to get there. Paid Mac converters exist (Owl3D, Spatial Media Toolkit) but they are closed boxes: no control over depth character, no inspection of what the model saw, nothing he can extend into the Mac plus headset companion architecture he actually wants.

## Wedge

The judgment loop, not the conversion. Every converter converts. Relief lets you see the depth before you commit: a depth map view, an anaglyph view, and a wiggle preview that makes bad depth obvious in two seconds without glasses. Convert is the last step, not the first. Owning the pipeline is the second wedge: this engine is the foundation for the live streaming route and the depth-track hybrid later.

## Why now

Three things landed recently and stack: Apple ships Depth Anything V2 as a Core ML package that runs on the Neural Engine, macOS 15 writes MV-HEVC spatial video through AVAssetWriter, and the Vision Pro is in the house. The hard parts of 2024 are the stock parts of 2026.

## Goal

A complete macOS app: drop 2D video in, judge and tune depth, export a spatial .mov that visionOS Photos, Files, and AVPlayer treat as native spatial video.

## Non-goals

- Real-time conversion or screen capture streaming (that is Route 2, a separate build on this engine)
- A visionOS companion app (future; this app's outputs already play natively on the headset)
- DRM content of any kind
- Cloud processing, accounts, or anything server-backed
- Windows or cross-platform
- Video editing features (trim, color, audio mixing)
- Spatial photo conversion (visionOS Photos already does it)

## Success

One number: one full-length 2D film, converted by Relief, watched end to end on the Vision Pro in spatial without switching back to the flat original.

Guardrails:
- Golden set passes (rubric below): every clip scores 4 of 5 or better on depth ordering and viewing comfort
- Sustains at least 15 fps conversion throughput at 1080p on luna-pro
- 100% of golden set exports are recognized as spatial by visionOS Photos and QuickTime on the Mac

## Evals are the spec (golden set)

The depth model is the product risk, so the eval set is part of this PRD, not an afterthought.

Golden set, five clips dropped in ~/Movies/ReliefGoldenSet plus one synthetic clip the app generates itself:

1. Dialogue: two people, static camera, shallow scene
2. Landscape: wide shot, sky, distant layers
3. Action: fast subject and camera movement, motion blur
4. Animation: CG feature footage
5. Hard detail: low light, hair, rain, or foliage edges

Rubric per clip, scored 1 to 5:
- Depth ordering: foreground and background never invert; subtitles and graphics sit at a stable, sane depth
- Edge integrity: no shimmer or halo at hair, fences, or high-contrast edges that draws the eye
- Temporal stability: depth does not pump or breathe across frames; scene cuts do not flash
- Comfort: 60 seconds of continuous viewing with no eye strain at Standard strength

The synthetic clip (a box translating over a gradient) is the automated check: it verifies stereo sign convention (near objects pop toward the viewer), frame parity with the source, and audio passthrough.

Regression plan: any change to the depth model, smoothing, or disparity mapping re-runs the golden set. Keep one exported output per version per clip so A/B on the headset is a file swap, not a rebuild.

## Solution at UX level

Single dark window, three panes. Queue on the left, viewer in the center, inspector on the right. Preview modes: Source, Depth, Stereo (anaglyph), Wiggle. Three strength presets (Soft, Standard, Deep) plus a convergence slider. Convert button exports MV-HEVC with audio passthrough and reveals or shares the file. Full spec in RELIEF_DESIGN.md.

## Risks and scope risk

The single most likely stall: the MV-HEVC writer. It is a niche API with exact format-description extensions and units that are easy to get subtly wrong. Mitigation is baked into the build prompt: Apple's own sample project is the ground truth for the writer code, and the escape hatch (export left and right as side-by-side ProRes, mux with the spatial CLI) means the pipeline never blocks on it.

Second risk: model quality on real footage. That is what the golden set exists to answer early, in Phase 1, before UI investment.

## Kill criterion

If, after tuning strength, convergence, and smoothing, the golden set cannot reach passing scores (real footage reads as cardboard or shimmers unwatchably), stop building UI and write the kill memo. The engine survives as the basis for the depth-track hybrid; the app does not ship.
