# Make It 3D for Vision Pro

The visionOS companion to the Mac app. It plays a depth track file and lets you
turn the depth dial while the film is on your face.

`VISIONOS_PRD.md` in the repo root is the spec. This file records what was
built, what was measured, and the decisions the PRD asked to have written down.

## Build and run

```
cd Vision
xcodegen generate
xcodebuild -project MakeIt3DVision.xcodeproj -scheme MakeIt3DVision \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=26.5' \
  -derivedDataPath .build build
```

On the headset. Signing is automatic under team `8J4SDPB6A2`, set in
`project.yml` rather than in Xcode, because xcodegen rewrites the project and a
team picked in the UI is gone at the next generate.

```
xcodebuild -project MakeIt3DVision.xcodeproj -scheme MakeIt3DVision \
  -destination 'generic/platform=visionOS' -derivedDataPath .build-device build
```

Install and launch on a booted simulator:

```
xcrun simctl install <device> .build/Build/Products/Debug-xrsimulator/MakeIt3DVision.app
xcrun simctl launch <device> com.russellwhite.makeit3d.vision
```

The app opens a control window and an immersive space. Use the test clip button
to write a synthetic depth track file and play it; the depth dial is in the
room, under the picture.

### The self test

Launching with `MAKEIT3D_SELFTEST=1` makes the app open the test clip, play it
while sweeping the dial, and write a report to its Documents directory.

```
SIMCTL_CHILD_MAKEIT3D_SELFTEST=1 xcrun simctl launch <device> com.russellwhite.makeit3d.vision
cat "$(xcrun simctl get_app_container <device> com.russellwhite.makeit3d.vision data)/Documents/selftest.txt"
```

Add `SIMCTL_CHILD_MAKEIT3D_TEST_SIZE=4k` to run the same thing at 3840 by 2160.

### The command line workbench

`DepthTrackTool` is a macOS target sharing every line of format and engine code
with the app. It writes fixtures and runs the gates headlessly.

```
Scripts/depth_sign_gate.sh          # builds the tool and runs the sign gate
.gate/depthtracktool gate --metal Sources/Engine/StereoWarp.metal
.gate/depthtracktool fixture --out ~/Desktop --frames 900 --tone
```

## The gates, and what they measured

Nothing here is an impression. Every line is a number.

| Gate | Where it runs | Result |
| --- | --- | --- |
| Stereo sign convention | build phase, and again in the app | near +2.6 px, far -7.0 px, both correct |
| Format conformance | `check-format` | 3 tracks, marker present, depth 960x540 from 1920x1080, shot values exact |
| Depth levels survive HEVC | `check-format` | mean 0.054 levels of 255 |
| Frame alignment, two minutes | `check-alignment` | 3600 frames, 0 drift, tolerance 0 |
| Compositor pairing | `check-pairing` | 300 frames, 300 exact, 0 approximate |
| Depth levels survive the colour path | `check-pairing` | mean 0.038 levels of 255 |
| Alignment through the real player | app self test | 361 frames checked, 0 mismatched |
| Pairing key in the player | app self test | 361 by buffer identity, 0 by time |
| Eyes identical at zero strength | app self test | 0.0000 levels, best shift 0 px |
| Eyes differ at the film's strength | app self test | 1.823 levels, best shift 9 px |
| Dial latency | app self test | worst 1 display frame over 47 changes |
| Warp cost at 1080p | app self test | 0.17 ms mean, 0.77 ms worst |
| Warp cost at 4K | app self test | 0.24 ms mean, 2.63 ms worst, against an 11.0 ms budget |

**The frame rate numbers above are from the simulator, which runs on this Mac's
GPU.** They say the shape of the pipeline is right and they say nothing at all
about the M2 in the headset. The device number is still owed.

## Decisions

### Route A, with the Mac's mesh warp

The PRD offered RealityKit with a per eye shader (Route A) or CompositorServices
with the Mac's mesh warp ported across (Route B), and asked which was chosen and
why. The answer is neither exactly: the parts that were good in each.

`CustomMaterial` is `@available(visionOS, unavailable)`. Verified in the SDK, not
assumed. So Route A as the PRD imagined it, a surface shader that branches on
camera index and samples at an offset, does not exist on this platform. What does
exist is `ShaderGraphMaterial` and the MaterialX node
`ND_realitykit_geometry_switch_cameraindex_color3`.

That node can choose between two textures per eye. It cannot do a warp. So the
warp stays where it already worked: Metal, offscreen, the Mac's mesh warp ported
across with its background plate and its guided upsample intact. Two eye
textures come out of it, and the material's only job is to show the right one to
the right eye.

This turns out to be better than either route on its own:

- The disocclusion objection to Route A disappears. There is no backward warp
  here; it is the same mesh warp plus background plate the Mac uses, so hard
  depth edges behave the way they already do in the Mac's output.
- The expensive work runs at video rate and the display runs at 90. A film at 24
  fps means 24 warps a second, not 90. The eye passes are textured quads.
- SwiftUI is still available, so the dial is a real native control in the room
  rather than something drawn by hand in Metal.

The shader graph is hand written USD, in `Sources/App/Resources/StereoScreen.usda`.
Four nodes is a file a person can read and review, which a Reality Composer Pro
binary is not.

**If the device measurement says this does not hold**, Route B is still open and
most of the work carries over: the warp, the format, the pairing and the checks
are all independent of how the eye textures reach the eyes.

### Measure pixels, not bookkeeping

Three times on this project something looked right and was not: the stereo sign
was inverted and the render looked fine, a colour frame was paired with a
neighbour's depth while the counters read 360 exact, and the two eyes differed
in scale by the overscan factor. Every time, the check that should have caught
it was measuring the pipeline's own bookkeeping rather than the pixels.

So the gates that matter render something and measure it. To find out whether
they actually work, the stereo was flattened on purpose, with the eye factor
forced to zero for both eyes. The result:

```
FAIL  Near content pops forward:                separation +0.00 px
FAIL  At the film's own strength the eyes differ: 0.000 levels, best shift 0 px
FAIL  More strength separates the eyes further:   0.000 against 0.000
PASS  Colour and depth stay aligned:              0 mismatched of 362
PASS  Pairing is exact, not approximate:          0 near, 0 missed
PASS  The screen has a per eye material:          per eye, camera index switch
PASS  The warp fits inside a video frame:         0.30 ms against 11.0 ms
PASS  The dial is visible within one frame:       worst 1 display frame
PASS  Frame rate holds while the dial moves:      119.7 fps
```

Six counters reading PASS over a completely flat picture. One of them was
called "Both eyes are being synthesized", which that run proved was a lie: it
checks that a material loaded, not that two pictures exist. It is now named for
what it does.

The build gate caught this too, before the app finished compiling, which is why
producing the flattened build at all required deliberately bypassing it.

### Pairing by buffer identity, not by timestamp

The first version keyed a colour frame to its depth frame by
`itemTimeForDisplay`, the time `AVPlayerItemVideoOutput` hands back with a
frame. The strips caught it doing the wrong thing roughly one frame in three
hundred: that time is not always the composition time of the frame returned, so
a frame occasionally matched a neighbour's depth exactly and the picture carried
the wrong frame's depth.

The compositor now publishes the colour buffer alongside the depth frame, and
the player looks up by the colour buffer's own identity. The player hands back
the exact object the compositor finished with, and object identity cannot be off
by a frame. Timestamp lookup is still there as a fallback and is counted
separately, so if identity ever stops holding the numbers will say so rather
than the picture quietly going wrong.

This is the second time on this project that something looked right and was not.
It is the argument for the strips.

### Where the dial lives

In the room, under the picture, not in the control window. A window sits at eye
height in front of you, which is on top of the screen, so reaching for a dial in
a window means the picture is behind the thing you are adjusting it with. The
console is a `ViewAttachmentComponent` under the screen, and how far under is a
control, because where a dial wants to be depends on how big the screen is.

### An immersive space, not a volume

The PRD's Phase 1 says a volume. A volume is capped at roughly two metres on a
side and the success condition is a whole film at theatre scale, which needs a
wall. The screen is three metres by default and adjustable to eight.

### One divergence from the Mac engine

On the Mac, `leftEyeUntouched` blits the source into the left eye and skips the
warp, which also skips the overscan the right eye gets. The two eyes then differ
in scale by 2.5%. On a monitor that is a curiosity. On a face it is a vertical
size mismatch between the eyes, which is a known way to make someone's eyes ache
in ten minutes.

Here the left eye goes through the same warp with an eye factor of zero. It
carries no disparity, exactly as intended, and lands on precisely the same
framing as the right. **This looks like a real bug on the Mac side and is worth
fixing there.**

### Colour

Decoded video is gamma encoded. Binding it as a linear texture and handing the
result to RealityKit makes mid grey land near white and the whole film wash out.
The colour path is sRGB end to end: the source is bound as `bgra8Unorm_srgb` so
the sampler linearizes on read, and the eye textures are sRGB so the warp
re-encodes on write.

Depth deliberately is not. Depth levels are data, not light, and a transfer curve
applied to them would bend the depth mapping with them.

## The format, and one thing the Mac side has to agree with

The depth track format is frozen in the PRD and this app implements it as
written. One thing the PRD names but does not give an equation for is how
`depthScale` and `depthOffset` map a shot's stored levels back into the film's
shared space. This app uses:

```
shared nearness = stored / 255 * depthScale + depthOffset
```

which is the natural reading, and is what `SyntheticDepthClip` writes and what
`upsampleNearness` in the shader consumes. **The Mac side has to use the same
equation or a cut will jump.** If the Mac has chosen the inverse, say so and the
PRD gets one clarifying line rather than either side changing quietly.

## Xcode's recommended settings

Xcode offers an "Update to recommended settings" sweep on this project. Do not
apply it. Not because the suggestions are wrong, but because they are written
into the `.xcodeproj`, which xcodegen regenerates from `project.yml`, so they
would quietly disappear at the next generate.

The two worth having are in `project.yml` already: dead code stripping is on,
and user script sandboxing is explicitly off.

Sandboxing is off because it breaks the sign gate, measured rather than assumed:

```
Sandbox: zsh deny(1) file-read-data Scripts/depth_sign_gate.sh
```

A sandboxed script phase may only touch files it declared as inputs and outputs.
The gate declares none on purpose: it compiles the checker across every source
folder and decides whether to re-run by hashing them, which is what keeps an
incremental build fast. Declaring every source file as an input would work and
would then have to be kept in step by hand, and a gate that stops running
because someone added a file is worse than no sandbox at all.

Hardened runtime on `DepthTrackTool` was skipped as well. It is a local
workbench that is never distributed, and the Mac app turns it off for the same
reason.

## Layout

```
Sources/Format/    the frozen format: writer, reader, synthetic generator
Sources/Engine/    the ported warp, the tuning, the paired frame compositor
Sources/Checks/    the gates, shared by the app and the command line tool
Sources/App/       the headset app
Tools/Gate/        the macOS workbench
Scripts/           the build phase gate
```

`Sources/Format`, `Sources/Engine` and `Sources/Checks` compile into both
targets. A gate that runs against a copy of the code proves something about the
copy.
