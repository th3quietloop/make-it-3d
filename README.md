# Relief

A macOS app that converts 2D video into Apple spatial video (MV-HEVC) for the Vision Pro.

Named for relief sculpture: depth raised from a flat surface. That is the whole product.

Drop a flat movie in, judge its depth in four preview modes, tune it, and export a `.mov`
that visionOS Photos, Files, and AVPlayer treat as native spatial video, with the original
audio passed through untouched.

The wedge is the judgment loop, not the conversion. Every converter converts. Relief lets
you see the depth before you commit: a depth map view, a half colour anaglyph, and a wiggle
preview that makes bad depth obvious in two seconds without glasses. Convert is the last
step, not the first.

## Requirements

- macOS 15 or later, Apple silicon
- Xcode 26 with the Metal Toolchain component installed
  (`xcodebuild -downloadComponent MetalToolchain`; the app has Metal shaders and will not
  build without it)

## Build loop

```bash
xcodegen generate
```

```bash
xcodebuild -project Relief.xcodeproj -scheme Relief -configuration Debug -derivedDataPath ./build build
```

```bash
open ./build/Build/Products/Debug/Relief.app
```

## Verifying an export

Relief ships its own gate. Run the app headless and it converts a synthetic clip it
generates itself, checks the stereo sign convention, and prints a verification report:

```bash
./build/Build/Products/Debug/Relief.app/Contents/MacOS/Relief --selftest
```

Pass file paths after the flag to push real clips through the same path:

```bash
./build/Build/Products/Debug/Relief.app/Contents/MacOS/Relief --selftest ~/Movies/clip.mov
```

The report checks four things, and they are the things that actually decide whether a file
reads as spatial:

1. **Spatial signalling.** The output's format description carries both the left and right
   stereo eye view flags. This is the same metadata QuickTime Player and visionOS Photos
   read to decide a file is spatial.
2. **Video layers.** Two MV-HEVC layers, plus the field of view, baseline, horizontal
   disparity adjustment, and projection kind.
3. **Frame parity.** The export has the same frame count as the source, within one frame.
4. **Audio passthrough.** The source audio survived the trip.

There is also a writer only probe, which feeds synthetic stereo pairs straight to the
MV-HEVC writer with no model and no warp in the loop. It is the fastest way to tell whether
a stalled export is the writer or something upstream of it:

```bash
./build/Build/Products/Debug/Relief.app/Contents/MacOS/Relief --selftest --writerprobe
```

### The final human check

None of the above proves the depth is comfortable to look at, and no automated check can.
**AirDrop an export to the Vision Pro and open it in Photos.** That is the real verification,
and it is the one step a person has to do.

## The golden set

Five clips live in `~/Movies/ReliefGoldenSet`, plus the synthetic clip the app generates:

1. Dialogue: two people, static camera, shallow scene
2. Landscape: wide shot, sky, distant layers
3. Action: fast subject and camera movement, motion blur
4. Animation: CG feature footage
5. Hard detail: low light, hair, rain, or foliage edges

Each is scored 1 to 5 on depth ordering, edge integrity, temporal stability, and comfort.
Any change to the depth model, the smoothing, or the disparity mapping re-runs the set. The
debug menu has a "Convert golden set" item that queues everything found in that folder and
writes a dated verification report next to each export.

## How it works

```
Ingest -> DepthEstimator -> Stabilizer -> Disparity -> WarpRenderer -> SpatialWriter
```

- **Ingest** reads the source through a video composition, so a rotated phone clip arrives
  upright, and hands frames to the pipeline one at a time. Pulling one frame at a time is
  the backpressure: the reader only decodes as fast as the model consumes, so memory stays
  flat on a feature length file.
- **DepthEstimator** runs Depth Anything V2 Small on the Neural Engine. The model declares
  its own input geometry (518x392 for this package) and Relief reads that at runtime rather
  than hardcoding it. Output is inverse depth, treated as nearness: higher means closer.
- **Stabilizer** normalizes each frame against its own 2nd and 98th percentiles, smooths
  across frames with an exponential moving average, and resets on scene cuts rather than
  smearing depth across them.
- **Disparity** maps nearness to pixels: `d = S * W * (nearness - C)`. Forward pop is halved
  afterwards, because content in front of the screen plane is the expensive direction for
  the eyes.
- **WarpRenderer** upsamples the depth map to frame resolution with a joint bilateral filter
  guided by frame luma, then displaces a Metal vertex grid horizontally. Triangles that
  straddle a depth discontinuity stretch across the gap, which is what covers disocclusions
  without an inpainting pass. Both views are overscanned 2.5% and cropped to hide the
  stretched edges.
- **SpatialWriter** writes MV-HEVC through `AVAssetWriter`: two tagged layers in one HEVC
  track, with the spatial metadata visionOS reads.

Every number the pipeline uses lives in `EngineTuning`. Nothing downstream hardcodes a
constant, so the golden set can tune the engine from one place.

## Notes from the build

Three things here are deliberate and would otherwise look like mistakes.

**The disparity sign is flipped once, in `EngineTuning`.** For an object nearer than the
screen plane, the ray from the left eye through it meets the screen to the right of centre
and the ray from the right eye meets it to the left. That is crossed disparity, and it means
the left eye's copy sits further right. The raw mapping produced the opposite, so the sign is
inverted in exactly one place. `SignConventionCheck` measures this from rendered pixels and
fails the gate if it ever changes.

**The writer goes through the double underscore CoreMedia symbols.** `CMTaggedBufferGroup`
and its create function are marked `CF_REFINED_FOR_SWIFT`, which hides the plain names from
Swift, and the refined replacement that can reach an asset writer input
(`AVAssetWriter.inputTaggedPixelBufferGroupReceiver`) is macOS 26 and later. Relief targets
macOS 15, so the unrefined C entry points are the supported way there. Building the group as
a `CMSampleBuffer` instead does not work: the writer input rejects it, because a tagged
buffer group sample buffer does not carry the `vide` media type the input requires.

**Eye buffers come from a pool, never from a reused pair.** The writer retains what it is
handed and the encoder reads it asynchronously, so a frame is not free to be overwritten just
because `append` returned. Reusing one pair corrupts frames in flight and wedges the writer.

## The sandbox decision

Relief is ad hoc signed, unsandboxed, and has no entitlements. This is a personal tool run
locally, not a distribution build. Skipping the sandbox removes security scoped bookmarks and
a whole class of file access friction: the app can read any movie the user drops on it and
write next to it without ceremony. If Relief were ever distributed, the sandbox and its
bookmark handling would have to come back.

## Non-goals

Real time conversion or screen capture streaming, a visionOS companion app, DRM content,
cloud processing, Windows, video editing, and spatial photo conversion. HDR sources are
converted to SDR Rec. 709, because the warp renders into 8 bit BGRA.
