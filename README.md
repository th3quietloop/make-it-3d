# Make It 3D

A macOS app for turning 2D video into Apple spatial video (MV-HEVC). Depth estimation, preview and conversion run on your Mac. The output is a `.mov` with stereo video and preserved source audio tracks.

The workspace is built around reviewing a short excerpt before exporting a full video. Desktop previews help inspect depth ordering, edges and motion; stereoscopic depth and viewing comfort still need review on Vision Pro.

This README describes the current source, including the **unreleased workspace and review update**. The latest signed download is still [v1.2.3](https://github.com/th3quietloop/make-it-3d/releases/tag/v1.2.3), which predates these changes. Build from source to try the updated workflow. See [release notes](RELEASE_NOTES.md) for the changes and remaining limits.

## Requirements

- macOS 15 or later on Apple silicon.
- Xcode 26 and its Metal Toolchain component.
- XcodeGen to generate the project.
- The bundled model resources under `MakeIt3D/Resources/Models`, included in a normal checkout.

## Build and run

From the repository root:

```bash
xcodebuild -downloadComponent MetalToolchain
xcodegen generate
xcodebuild -project MakeIt3D.xcodeproj -scheme MakeIt3D -configuration Debug \
  -derivedDataPath ./build CODE_SIGNING_ALLOWED=NO build
open ./build/Build/Products/Debug/MakeIt3D.app
```

The app bundle and executable are both named **MakeIt3D**, without spaces. The application display name is **Make It 3D**. Use `open` to launch the interactive app. Run the executable directly for headless checks.

To add a video at launch:

```bash
open ./build/Build/Products/Debug/MakeIt3D.app --args ~/Movies/clip.mov
```

The generated project includes the maintainer's signing settings. Use your own identity for signed development or distribution builds. The unsigned commands above do not require that identity and do not create a notarized release.

## Review and export a video

1. **Open a video or the sample.** Drop a video onto the window, use Add to Queue, or choose the app in Finder's Open With menu. The sample is a credited excerpt from *Big Buck Bunny*; see [sample attribution](MakeIt3D/Resources/Samples/SAMPLE_ATTRIBUTION.md).
2. **Let automatic depth prepare.** The app analyses detected shots and keeps their automatic settings separate from your adjustments. Preparation is scheduled one video at a time.
3. **Watch Original, then inspect.** Original plays the source video. Compare eyes switches between still eye views; Show Other Eye provides a deliberate step. Depth map and Red-cyan glasses are secondary modes. Compare Your settings, Automatic and Original at the same time and crop. Actual size (100%) requests source-resolution imagery for detail inspection.
4. **Adjust depth.** Strength and balance stay visible in the inspector. Choose This shot or Whole video before editing. Whole video applies the changed parameter across shots. Reset restores automatic values within the chosen scope. Save named variants to revisit alternatives.
5. **Make a short proof.** Choose a 3-, 5- or 8-second excerpt, using Automatic or your settings. Play and loop the converted proof, compare it with the original at matching source time, and inspect it on the headset. Desktop proof playback shows one eye. Later adjustments mark the proof as out of date.
6. **Review export details.** Convert opens a preflight sheet with destination, filename, dimensions, audio tracks, approximate size, source availability and free-space checks. Existing files are preserved; a taken name gets a numbered alternative.
7. **Check the result.** A completed export reports file checks separately from headset viewing. Failed verification remains a recoverable failure with its report. History keeps proof, success and failure records, with review, Finder and sharing actions.

Review shots opens a contact sheet with motion and edge risk indicators. These are inspection hints, not quality or comfort certification. Bookmarks, time entry and 2-, 10- or 30-second timeline windows help return to a frame. The queue can be resized or hidden, and Focus viewing hides side panels to enlarge the stage.

Under More controls, Edge cleanup crops the image slightly; Edge detail cleanup softens abrupt depth boundaries; Moving subject stability reduces reliance on older depth around motion. Rebuild hidden areas uses available earlier-frame information and a nearby-pixel fallback. Inspect these tradeoffs in a moving proof. Headset playback controls write viewing metadata and do not change the preview image.

## Queues, sessions and history

- Search names or paths and filter Waiting, Failed or Converted. Range selection and Select All follow the visible rows.
- Drag an ordered selection or use the queue commands to move it. Convert Next keeps the active conversion running.
- Export Selected uses a fixed selection snapshot. Export All Ready can admit videos added during its run.
- Pause after the current video, resume, stop after it, stop now, skip or retry. A canceled re-export preserves its earlier completed output.
- Copy depth, cleanup or model settings to a selected batch independently. Active conversions are excluded.
- Depth edits and queue edits support Undo and Redo. Sliders group a continuous drag as one edit.
- Queue, settings, shot analysis, bookmarks, variants and export history are saved automatically under `~/Library/Application Support/MakeIt3D`.
- Save Session As writes a JSON session; Open Session restores it. Sessions reference source and output paths instead of embedding media. Locate source reconnects an unavailable original. An existing completed export remains available if its original is missing.
- Interrupted exports restart from the beginning after recovery. They do not resume at a partial encoded frame.
- History opens durable export records. Its Messages action opens the current launch's message history. Failure messages remain until dismissed, without covering the video.

Quitting during a full conversion asks before cancellation, then waits for cleanup and saves the recovered workspace. Notifications and Dock progress provide background status; notifications require macOS permission.

## Useful shortcuts

The menu bar is the complete shortcut reference. Common actions:

| Action | Shortcut |
| --- | --- |
| Add videos | ⌘O |
| Open session / Save Session As | ⇧⌘O / ⌘S |
| Undo / Redo | ⌘Z / ⇧⌘Z |
| Export selected / All ready | ⌘Return / ⇧⌘Return |
| Export history | ⇧⌘H |
| Original / Depth map / Red-cyan glasses / Compare eyes | 1 / 2 / 3 / 4 |
| Play or pause Original/proof; toggle eye alternation in Compare eyes | Space |
| Show other eye | ⌘E |
| Make a five-second proof | ⇧⌘P |
| Bookmark frame | ⌘B |
| Previous / next frame | ⌘← / ⌘→ |
| Back / forward one second | ⇧⌘← / ⇧⌘→ |
| Stop queue now | ⌘. |
| Show exported file / Share to headset | ⌘R / ⇧⌘S |

## Depth models and performance

**Normal** uses Depth Anything V2 Small, with temporal smoothing and motion-aware rejection. **Steady (slow)** uses Video Depth Anything Small when available. Steady is experimental and can be much slower; its still preview uses Normal depth, so use a converted proof to judge the temporal model.

Settings contains model tools:

- **Measure on This Mac** compares compute preferences using a warm-up and three source frames. These measurements cover per-frame depth inference, not full export throughput. Decode, reconstruction, encoding, resolution and footage also affect completion time. Export history gradually provides estimates from actual runs on this Mac.
- **Import Core ML Model** accepts a compatible `.mlpackage` or `.mlmodelc`. The app copies it, checks input/output compatibility, runs calibration inference and stores a checksum before activation. **Use Built-in** returns to the bundled model. Imported models must match the supported estimator contract; arbitrary Core ML models are not interchangeable.
- **Download…** accepts an HTTPS ZIP URL and its publisher's SHA-256 checksum, both supplied by you. It verifies the archive hash, checks archive paths and size limits, then runs the same model validation before activation. Downloads are explicit; there is no curated catalog of automatically trusted model sources. The previous model remains active if validation fails.

Model conversion scripts live in `Tools/modelconv`. See [NOTICE.md](NOTICE.md) for the bundled models' Apache 2.0 notices and [LICENSE](LICENSE) for the app's MIT license. A compatible model passing calibration is not proof of visual quality; review representative footage after changing it.

## Verification gates

### Regression tests and CI

```bash
xcodegen generate
xcodebuild -project MakeIt3D.xcodeproj -scheme MakeIt3D -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath ./build \
  CODE_SIGNING_ALLOWED=NO test
```

The XCTest target covers scheduler ordering, cancellation, retry, settings scope, persistence, proof state, navigation and engine regressions. The [CI workflow](.github/workflows/ci.yml) builds and runs it on the configured macOS runner, then retains its result bundle. Hosted CI excludes the generated-media test that needs the physical Mac's spatial-video encoder; the command above and native self-test run that gate locally. A normal `build` does not run tests, and hosted CI does not prove physical hardware encoding or headset playback.

### Native media release checks

Run the headless self-test on a physical Apple silicon Mac:

```bash
./build/Build/Products/Debug/MakeIt3D.app/Contents/MacOS/MakeIt3D --selftest
```

It exercises stereo sign and disocclusion checks, synthetic end-to-end conversion, and generated media regressions for variable frame timing, long audio tails, multiple audio tracks, range exports, custom metadata, destination protection and cancellation cleanup. It prints the working directory and exits with failure if a required check fails.

To include a real clip:

```bash
./build/Build/Products/Debug/MakeIt3D.app/Contents/MacOS/MakeIt3D --selftest ~/Movies/clip.mov
```

The temporal model is an explicit, potentially lengthy extra gate:

```bash
./build/Build/Products/Debug/MakeIt3D.app/Contents/MacOS/MakeIt3D --selftest --include-video-model
```

That option exercises the video model only when it is available. Without the option, the temporal path is reported as skipped. For a writer-only diagnostic that excludes depth inference and warping:

```bash
./build/Build/Products/Debug/MakeIt3D.app/Contents/MacOS/MakeIt3D --selftest --writerprobe
```

Export verification reads the output back through AVFoundation, checks stereo signaling and layers, compares decoded frame counts, and checks audio track count, timing, duration and language. The external `spatial` utility supplies an additional check when installed. Its absence is reported as **Not checked / SKIP**, not as a successful external check. File verification does not certify depth quality or viewing comfort.

### Human release checks

Inspect short proofs and completed exports on Vision Pro in Photos. Use representative dialogue, landscapes, fast action, animation and difficult detail such as hair, foliage and low light. Record depth ordering, edge integrity, temporal behavior, audio and comfort. Repeat this review after depth model, smoothing or reconstruction changes.

`Scripts/release.sh` runs the native self-test and regression tests before signing validation, notarization, stapling and packaging. It requires configured signing and notarization credentials. Headset review remains a separate release gate; the script cannot perform it. Use a Release build for performance measurements.

## Pipeline and limits

```text
Ingest → DepthEstimator → Stabilizer → Disparity → WarpRenderer → SpatialWriter
```

Ingest handles video orientation and frame timestamps. Depth inference produces nearness; smoothing and shot changes manage its temporal behavior. Disparity maps that depth into an eye shift. Reconstruction uses depth edges, the source image and available background history. SpatialWriter writes tagged stereo buffers into MV-HEVC and preserves supported source audio tracks. Export captures the same automatic settings plus explicit overrides used by the inspector.

- Monocular depth can produce incorrect boundaries, halos and internally flat objects. Cleanup controls reduce some artifacts but do not reconstruct unseen geometry reliably.
- Still previews do not reproduce the full temporal history of an export. Use a moving proof for motion, temporal depth and filling behavior.
- HDR preservation is not implemented. The current render path uses 8-bit buffers; HDR source color appearance requires separate review. The experimental HDR writer probe is a capability investigation, not an HDR export feature.
- Model inference can be slow to cancel; cleanup waits for the current operation to return.
- Session media stays at its existing paths. Moving a session JSON alone does not move its videos.
- The app uses an unsandboxed Developer ID distribution configuration. Notarization is a release step, not a property of every local build.

Real-time conversion, DRM removal, cloud processing, a visionOS companion, Windows, full video editing and spatial photo conversion are outside the current app.

## Regenerate the icon

```bash
./build/Build/Products/Debug/MakeIt3D.app/Contents/MacOS/MakeIt3D --makeicon MakeIt3D/Resources/Assets.xcassets
```
