# Make It 3D for Vision Pro: PRD

A visionOS app that plays the output of Make It 3D and lets you change the depth while you
are wearing the headset.

## The one reason this exists

Photos on visionOS already plays MV-HEVC natively. A visionOS app that browses a library and
plays it back would be a worse Photos, and building one is a waste of a week.

There is exactly one thing a native app can do that Photos cannot: **let you turn the depth
dial while the video is playing on your face.**

Today the loop is broken across two machines. You guess a depth setting on a flat monitor,
convert, AirDrop, put the headset on, and find out. If it is too strong you take the headset
off and start again. You are judging depth in one place and experiencing it in another. That
seam is the whole product.

## User

Russell. One user. He has a Mac that makes spatial video and a Vision Pro that plays it, and
no way to tell whether a depth setting is right until after he has committed an hour of
conversion to it.

## Wedge

Depth stops being baked into pixels and becomes data the player can reinterpret. Once depth
ships alongside the video instead of inside it, the headset can rebuild the second eye every
frame at whatever strength you ask for, live, with no reconversion.

That is also the foundation for everything after it: per shot tuning that you can audit in
the headset, and eventually a depth track hybrid that halves nothing but makes everything
adjustable forever.

## Goal

Put on the headset, open a file made by Make It 3D, watch it at theatre scale, and change the
depth with a pinch and drag without the picture stopping.

## Non-goals

Say these out loud because each one is a plausible week that produces nothing.

- A photo or video library browser. Photos owns that. Open files from Files and from Photos.
- A Photos clone of any kind.
- Editing, trimming, colour, audio.
- Doing depth estimation on the headset. The Mac does that. The M2 in the headset is busy
  drawing two eyes at 90 Hz.
- Streaming from the Mac in real time. Later, different product.
- DRM content of any kind.
- Replacing MV-HEVC. Make It 3D keeps writing standard spatial video that plays in Photos.
  The depth track format is an addition, never a substitute, because "it just works in
  Photos" is the best property the Mac app has and losing it would be a downgrade.

## Success

One number: watch one full length film in this app, adjust the depth at least once mid film
because it felt wrong, and never take the headset off to fix it.

Guardrails:

- Holds 90 fps at 4K per eye with the warp running, on device, measured not assumed
- Depth changes are visible within one frame of the gesture, with no stall and no reload
- Plays every file Make It 3D has ever written, including plain MV-HEVC with no depth track
- Zero crashes across a two hour playback

## The format contract

This is the part that matters most, because the Mac app and this app are being built in
parallel by two people who cannot see each other's work. The format is the interface. It is
frozen here and neither side changes it without changing this document.

**Container.** A QuickTime `.mov`. Nothing exotic. If you open it in QuickTime or Photos you
see an ordinary video, because everything extra rides in tracks a normal player ignores.

**Track 1, video.** The original 2D source, copied through untouched. Same codec, same
bitrate, same frame count. No re-encode. This is the left eye and it is never synthesized,
so it stays exactly as filmed.

**Track 2, depth.** A second video track carrying the depth map as luminance.

- Codec: HEVC, monochrome if the encoder allows it, otherwise 4:2:0 with chroma ignored
- Frame rate: identical to track 1, frame for frame, no drops
- Resolution: source width and height divided by 2, rounded up to even. Depth is smooth, and
  half resolution halves the decode cost for a difference nobody can see after the warp.
- Encoding: 0 is the farthest point in the shot, 255 is the nearest. Linear in between.
- Normalization: per shot, not per frame. Per frame normalization is what makes depth pump
  and breathe. The scale and offset that map each shot back to a common space live in the
  metadata track.

**Track 3, timed metadata.** One sample per shot, spanning that shot's time range, carrying
JSON:

```json
{
  "version": 1,
  "shot": 4,
  "depthScale": 0.83,
  "depthOffset": 0.06,
  "suggestedStrength": 0.016,
  "suggestedConvergence": 0.41,
  "comfortLoad": 0.72
}
```

- `depthScale` and `depthOffset` map this shot's 0 to 255 back into the film's shared depth
  space, so a cut does not flash
- `suggestedStrength` is S as a fraction of frame width, the same S the Mac engine uses
- `suggestedConvergence` is C, where nearness maps to zero disparity
- `comfortLoad` is the Mac's own verdict, 1.0 meaning exactly on the comfort budget

The player starts from the suggestions and lets the user override them live. The suggestions
are the Mac's opinion. The dial is the user's.

**Marker.** A top level `com.russellwhite.makeit3d.depthtrack` metadata item with value `1`,
so the player can tell a depth track file from a plain one without probing every track.

**Fallback.** No depth track means play it as ordinary MV-HEVC with the depth dial disabled
and a line saying why. Every file Make It 3D has ever produced must open.

## Rendering

The requirement is per eye synthesis at frame rate with a live strength control. Two routes
are viable and the build session must verify which one actually holds 90 fps before
committing:

**Route A, RealityKit with a per eye shader.** A plane entity with the video as texture and
depth as a second texture, and a surface shader that branches on the camera index so each eye
samples at its own horizontal offset. Far less code. Backward warping only, which means
disocclusion has to be handled by sampling rather than by geometry, and edge quality needs
checking against the Mac's mesh warp output before this is accepted.

**Route B, CompositorServices.** A fully immersive `CompositorLayer`, both eye buffers under
direct Metal control, and the Mac app's existing mesh warp ported across. Both machines are
Apple Silicon and the shader is already written, in
`MakeIt3D/Engine/WarpRenderer.swift` and its Metal source. Correct, higher fidelity, more
work, and it takes over the whole display.

Start with Route A because it is a day rather than a week, measure it against the Mac app's
output on the same frame, and fall through to Route B if the edges do not hold up. Write down
which one was chosen and why.

## Phases with hard gates

Do not proceed past a gate that has not been demonstrated.

**Phase 0. Synthetic first.** Before any player exists, write a generator that produces a
conforming depth track file from scratch: a box translating over a gradient, exactly the
trick the Mac app used. This removes any dependency on the Mac app being finished, gives the
reader something real to eat on day one, and doubles as the regression fixture forever.
Gate: a file on disk that `AVAssetReader` opens, with three tracks and parseable JSON.

**Phase 1. Read and play.** Open a depth track file, decode both video tracks in lockstep,
and put the left eye on a plane in a volume. No stereo yet. Gate: video and depth stay frame
aligned across a two minute clip with zero drift.

**Phase 2. Two eyes.** Synthesize the right eye from depth and show a real stereo image at
the suggested strength and convergence. Gate: it reads as 3D on the actual device, and near
objects pop toward the viewer rather than away. Verify the sign the same way the Mac app
does, by measuring rendered pixels, not by looking.

**Phase 3. The dial.** A pinch and drag that changes strength live while playing. Gate:
90 fps holds while dragging, and the change is visible within one frame.

**Phase 4. The room.** Scale, distance, and a dimmable surround so the picture is the
brightest thing in the space. Gate: a full film watched end to end without touching a
control.

## Risks

**The warp at 90 fps per eye is the whole risk.** The Mac manages roughly 30 fps at 1080p
doing depth estimation and warping together. The headset only has to warp, which is far
cheaper, but it has to do it twice, at higher resolution, at three times the rate, on a
smaller chip. If Phase 3 cannot hold frame rate, the dial becomes a control you set between
scenes rather than during them, and the product is still worth having but the story changes.
Measure this in Phase 2, not Phase 4.

**Disocclusion on a backward warp.** Route A cannot fill holes the way the Mac's mesh warp
plus background plate does. Compare against the Mac output on a hard depth edge before
accepting Route A.

## Kill criterion

If, after Phase 3, changing depth live cannot be made to feel instant, stop. The rest of the
app is a worse Photos and Photos is free. The depth track format survives as the thing that
makes Make It 3D's output future proof, and this app does not ship.
