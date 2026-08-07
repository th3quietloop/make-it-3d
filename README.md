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

Launch it with `open`, not by running the binary directly. Running
`Relief.app/Contents/MacOS/Relief` from a shell starts the process and installs
its menu bar, but the window never appears, because the app is not registered
with the window server that way. The headless modes below are the exception:
they never open a window, so running the binary directly is exactly right for
them.

Any movie paths passed after the app are added to the queue at launch, which
saves a trip through the open panel when you are testing one file repeatedly:

```bash
open ./build/Build/Products/Debug/Relief.app --args ~/Movies/clip.mov
```

## The app icon

The icon is generated, not drawn by hand. It is the stereo fuse at icon scale:
two rounded frames, one vermilion and one cyan, offset horizontally and screen
blended so the overlap resolves to near white, on the stage colour.

```bash
./build/Build/Products/Debug/Relief.app/Contents/MacOS/Relief --makeicon Relief/Resources/Assets.xcassets
```

That writes every size the asset catalog needs, drawn natively at each size
rather than downscaled from 1024 so the stroke stays crisp at 16pt, and packs an
`.icns` alongside it with `iconutil`.

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

### Measured throughput

On an M-series Mac, Release build:

| Source | Throughput |
| ------ | ---------- |
| 1280x720 | 32.9 fps |
| 1920x1080 | 30.0 fps |

The PRD guardrail is 15 fps at 1080p, so there is roughly double the headroom.
Resolution costs less than it looks like it should, because the depth model runs
at its own fixed 518x392 no matter what the source is. Only the warp and the
encode scale with pixel count.

Debug builds run about a third of this. Measure in Release.

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

## The language rule

The engine thinks in convergence, disparity, overscan, and baseline. The
interface does not use any of those words.

A person converting a home video thinks in "how much depth" and "does this look
right", so every control is named for what it does to the picture: Depth
strength, Depth balance, Edge cleanup, Fine-tune strength. The terms of art are
still there, in the tooltips, for anyone who wants them.

The same rule killed the old readouts. "In front 2.7 px, behind 4.4 px" answered
a question nobody asked and left the only real one unanswered, so it became a
gauge that says "Good depth" or "Too strong" with a line about what that means
for watching it. The pixel values live in that gauge's tooltip.

Field of view and baseline are grouped separately, under Headset playback, and
say plainly that they change the file's metadata rather than the conversion. A
control sitting next to a picture that does not change the picture teaches people
that the controls here are decorative.

## Telling the user what is happening

A feature length conversion runs for an hour, and the whole premise is that you
walk away. So:

- Toasts report every event: a file added, a duplicate skipped, a file Relief
  cannot read, a conversion finished, a conversion failed. Successes retire
  themselves after a few seconds; failures stay until dismissed, because a
  message you missed is a message that failed.
- System notifications fire on finish and failure, but only when Relief is not
  the frontmost app. Permission is asked for at the first conversion, not at
  launch.
- The Dock icon carries a progress bar, so the Dock answers "is it still going"
  without switching apps.
- Queue rows show time remaining, not just a percentage. "About 25 min left" is
  information; "40%" on a two hour film is anxiety.
- Quitting mid conversion asks first. It is the one genuinely destructive,
  genuinely irreversible action in the app.

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

## Where the eye views come from

The left eye is the source frame, untouched, and the right eye carries the whole
disparity. Warping both eyes by half sounds fairer and is not: the visual system
favours the sharper eye, so one perfect view next to one rebuilt view reads
cleaner than two half rebuilt ones. It is also cheaper, because the left eye is
a blit rather than a render. Symmetric is still available under More controls.

Shifting a frame sideways uncovers areas that eye never saw. The mesh used to
stretch a neighbouring pixel across those gaps, which is why the export cropped
in 2.5% to hide the smear. Relief now keeps a **background plate**: as
foreground moves across a shot, whatever is behind it gets remembered, and the
gaps are filled from that instead. The warp measures its own horizontal stretch
per triangle and discards anything past the limit, so the plate shows through
exactly where the smear used to be and nowhere else. The plate resets on a scene
cut, because a memory of the previous shot is worse than no memory at all.

Discarding pixels is only safe if something is underneath them, so
`DisocclusionCheck` renders the hardest case (a hard depth edge at Deep
strength) and counts how many output pixels came out as nothing. It runs as part
of `--selftest`.

## Depth models

Relief ships **Depth Anything V2 Small** (Apache-2.0), which reads one frame at
a time. Per frame models have no memory, so their output wobbles slightly even
when the picture barely moves, and Relief smooths that with an exponential
moving average. That trades flicker for lag and fixes neither properly.

**Video Depth Anything Small** (also Apache-2.0) is the actual fix: it reads a
window of frames and is steady across a shot by construction. The upstream
project ships no Core ML build, and the request for one had been open since
January 2025, so `Tools/modelconv/convert_vda.py` is the build step. The engine
side is done either way: `WindowedDepthEstimator` sits alongside the per frame
protocol, and `ConversionController` picks a loop based on which model is asked
for, falling back to per frame whenever the video model is not in the bundle.

```bash
cd Tools/modelconv && uv venv --python 3.11 .venv
uv pip install --python .venv/bin/python torch==2.7.0 torchvision==0.22.0 coremltools einops opencv-python-headless easydict huggingface_hub
.venv/bin/python convert_vda.py --frames 32
```

Three things had to be dealt with to get it through the converter, all recorded
in that script. The model reads frame counts and patch grids off its tensors,
which under a trace become one element arrays rather than integers, and
coremltools stops at the int() cast. The window size is fixed at conversion
time, so those values are pinned as literals instead. The temporal head's
intermediate resolutions are recorded on a warmup pass and then used as
constants. And the converter's scalar cast is widened to accept a one element
array, because a one element array holding 37 and the integer 37 mean the same
thing to every op downstream.

The window is 32 frames with 10 frames of look ahead, matching upstream. Each
window picks its own scale for relative depth, so the overlapping frames are
fitted onto the previous window's values before anything is written. Without
that the depth steps visibly at every seam.

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
