# Unreleased — workspace and review update

Make It 3D converts 2D videos into spatial `.mov` files on your Mac. This update makes it easier to inspect a short proof, keep useful settings and recover a session before committing to a full export.

## A clearer review workflow

- A larger viewing stage, resizable queue and Focus viewing mode.
- Original video playback, deliberate Compare eyes, Depth map and Red-cyan glasses inspection modes.
- Source-resolution 100% inspection, matching-frame comparisons of Your settings / Automatic / Original, bookmarks, time entry, timeline zoom and a shot contact sheet.
- Always-visible Adjust depth controls with explicit This shot and Whole video scope, independent resets, Undo and named variants.
- Three-, five- and eight-second converted proofs, looping playback and original/proof comparison. Later edits mark a proof as out of date; History retains previous proofs.
- Edge detail cleanup and moving-subject controls, with motion and edge risk hints for review.

## Safer exports and recoverable work

- Export preflight shows destination, name, size, audio and source/free-space problems before encoding.
- Existing outputs are preserved, including when a re-export is canceled or fails. Destination names are sanitized and new files are published without replacing an existing file.
- Failed file verification remains a failure with a readable report. Optional external checks clearly say Not checked when unavailable.
- Decoded frame counts support variable-rate footage. Audio verification includes multiple tracks, timing, duration and language.
- Automatic local workspace saving, explicit JSON sessions, reconnecting missing originals, durable export history and grouped editing Undo.
- Visible-order range selection, keyboard queue reordering, batch settings subsets and stage-aware progress.
- Failure messages stay until dismissed in a reserved message rail. Message history and export history remain accessible without covering the video.
- Quit and cancellation wait for cleanup. Interrupted exports can restart; completed output files remain available.

## Local model tools

Settings can import a compatible Core ML model, validate it with inference, record its checksum and return to the built-in model. Measure on This Mac compares compute options for per-frame depth inference. This is a calibration measurement, not a full export benchmark.

The optional Download flow accepts a user-provided HTTPS ZIP URL and publisher checksum. Archive checks and inference validation run before activation; it does not supply a curated or automatically trusted model catalog.

Normal depth remains the default. The Steady temporal model is experimental and may be extremely slow. Still inspection uses Normal depth even when Steady is selected; render a proof to inspect Steady's output.

## Verification and release status

The CI workflow builds and runs XCTest regressions, excluding the generated-media test that needs a physical Mac's spatial-video encoder. Local XCTest and native self-tests exercise that media gate on physical Apple silicon hardware. They do not run on every ordinary build. The temporal model self-test is optional through `--selftest --include-video-model`; the writer-only diagnostic is `--selftest --writerprobe`.

The release script runs native checks and regression tests before notarization and packaging. Passing code or file checks does not prove visual depth quality. Review exports on Vision Pro before releasing a build. These notes describe development changes, not a newly published or notarized download. The existing signed download remains [v1.2.3](https://github.com/th3quietloop/make-it-3d/releases/tag/v1.2.3).

## Remaining limits

Depth can still produce cutout edges, halos, incorrect ordering or objects that look internally flat. Motion cleanup and edge controls are tradeoffs, not comfort guarantees. Desktop playback of a proof shows one eye. Judge stereoscopic depth and comfort on the headset.

HDR preservation is not implemented; an experimental writer capability probe does not add HDR export. Session files reference media paths and do not package the source videos. Canceled exports restart from the beginning.

Requires macOS 15 or later on Apple silicon. Build and command instructions are in [README.md](README.md). The app is MIT licensed; see [NOTICE.md](NOTICE.md) for model notices and [sample attribution](MakeIt3D/Resources/Samples/SAMPLE_ATTRIBUTION.md) for the included film excerpt.
