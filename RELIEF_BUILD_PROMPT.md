# Relief: Build Prompt

You are building Relief, a complete macOS app that converts 2D video into Apple spatial video (MV-HEVC) for Vision Pro. You are building it for Russell White on luna-pro (Apple silicon, macOS 15+). RELIEF_PRD.md and RELIEF_DESIGN.md sit next to this file. Read both fully before writing any code. The PRD defines what and why. The design file defines exactly how it looks and behaves; Phase 3 implements it verbatim.

You build all three phases in this session, in order, without pausing for approval between them. Each phase ends with an app that compiles, launches, and does what its gate says. Complete means complete: no TODO comments, no stub functions, no placeholder views, no "add your logic here."

## Hard rules

1. Punctuation: never use em dashes, en dashes, or double hyphens in any text you write: prose, code comments, UI strings, documentation, commit messages, filenames. Use periods, commas, colons, parentheses. The single exception is required long-form CLI flags (such as gh repo create flags), which are shell syntax, not punctuation. Keep those to the minimum the command needs.
2. Fonts: SF Pro and SF Mono only. No serif faces anywhere, in any state.
3. Tooling: all git, GitHub, and build operations happen via CLI (git, gh, xcodegen, xcodebuild). Never route to a web dashboard for something the CLI can do.
4. API honesty: when you are not certain of a SwiftUI, AVFoundation, Core ML, or VideoToolbox signature, verify before writing it. Apple's structured docs are at https://developer.apple.com/tutorials/data/documentation/{framework}/{symbol}.json. For the MV-HEVC writer specifically, Apple's sample code is the ground truth (listed under Reference below). Do not guess constant names or metadata units.
5. Commit at every numbered checkpoint with a short message describing the state, for example: git commit -m "phase 1: depth engine produces stable maps on sample clip"
6. Swift 6, structured concurrency, no force unwraps in shipping paths, every view gets a #Preview with realistic sample data.

## Project setup

1. Find the next project number: list ~/Developer, take the highest leading number, add one. Call it NNN.
2. Create ~/Developer/NNN_macos_media_relief and git init inside it.
3. Copy RELIEF_PRD.md, RELIEF_DESIGN.md, and this file into the repo root.
4. Install xcodegen if missing (brew install xcodegen). Create project.yml:

```yaml
name: Relief
options:
  bundleIdPrefix: com.russellwhite
  deploymentTarget:
    macOS: "15.0"
targets:
  Relief:
    type: application
    platform: macOS
    sources: [Relief]
    settings:
      base:
        SWIFT_VERSION: "6.0"
        CODE_SIGN_IDENTITY: "-"
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
    info:
      path: Relief/Info.plist
      properties:
        NSHighResolutionCapable: true
```

Verify this against current xcodegen syntax if generation fails. Ad hoc signing, no sandbox, no entitlements: this is a personal tool run locally, not a distribution build, and skipping security-scoped bookmarks removes a whole class of friction. Note that consciously in the README.

5. Build loop for the whole session: xcodegen generate, then xcodebuild -project Relief.xcodeproj -scheme Relief -configuration Debug -derivedDataPath ./build build, then open the built .app from ./build/Build/Products/Debug.
6. Create the GitHub repo and push: gh repo create relief --private --source . --push
7. Checkpoint commit.

## Reference ground truth

- Apple sample code: "Converting side-by-side 3D video to multi-view HEVC and spatial video" on developer.apple.com. This is the authority for the MV-HEVC writer: the tagged buffer adaptor, the layer IDs, the stereo view group tags, and the spatial metadata extension keys and their units. Fetch it and read the writer portion before Phase 1 step 7.
- WWDC sessions by title: "Deliver video content for spatial experiences" and "Build compelling spatial photo and video experiences."
- Depth model: apple/coreml-depth-anything-v2-small on Hugging Face.
- Validation oracle: Mike Swanson's spatial CLI (install instructions at blog.mikeswanson.com; verify the current tap). Used to inspect exported files, and it is also escape hatch 1.

## Architecture

```
Relief/
  App/
    ReliefApp.swift          main scene, Settings scene, menu commands
    AppModel.swift           observable root: queue, selection, settings
  Engine/
    Ingest.swift             AVAssetReader frame source, probing, thumbnails
    DepthEstimator.swift     protocol + CoreML implementation
    Stabilizer.swift         normalization, EMA, scene cut reset
    Disparity.swift          nearness to disparity mapping, clamps
    WarpRenderer.swift       Metal mesh warp, left and right synthesis
    AnaglyphCompositor.swift half-color anaglyph for preview
    SpatialWriter.swift      AVAssetWriter MV-HEVC, audio passthrough
    ConversionController.swift  pipeline orchestration, progress, cancel
  Features/
    QueueSidebar/
    Stage/
    Inspector/
    EmptyState/
  DesignSystem/
    Tokens.swift             every color, spacing, radius, type token from RELIEF_DESIGN.md
    Components/
  Resources/
    Models/                  the mlpackage lands here
  TestKit/
    SyntheticClip.swift      generates the parity test clip
```

Data flow: Ingest produces frames as an AsyncStream with backpressure. Each frame passes through DepthEstimator, Stabilizer, Disparity, WarpRenderer, and lands in SpatialWriter as a left and right pair. ConversionController owns the task, publishes progress, and supports cancellation at frame boundaries.

## Algorithm spec

Follow these numbers. They are starting values the golden set will tune, so route every one of them through a single EngineTuning struct.

- Model input: read the model's own input description at runtime (MLModel modelDescription) and resize with aspect fill to whatever it declares (expect roughly 518 on the long side). Do not hardcode the size.
- Model output is inverse depth: treat it as nearness, higher means closer.
- Normalization: per frame, clamp to the 2nd and 98th percentiles, then scale to 0...1.
- Temporal smoothing: exponential moving average across frames with alpha 0.2. Scene cut detection: if mean absolute nearness delta between consecutive frames exceeds 0.18, reset the EMA to the new frame.
- Upsample the depth map to frame resolution with joint bilateral upsampling guided by frame luma.
- Disparity: d = S times W times (nearness minus C), in pixels, where W is frame width, C (convergence) defaults to 0.45, and S (strength) is Soft 0.010, Standard 0.016, Deep 0.024. After mapping, scale positive d (content in front of the screen plane) by 0.5 so forward pop stays inside the comfort budget.
- Synthesis is symmetric: left eye view samples at x plus d over 2, right eye view at x minus d over 2.
- Sign convention check, do this before trusting anything: in the synthetic test clip, the near box must appear to pop toward the viewer (in wiggle preview the near object swings opposite to the background). If it reads inverted, flip the sign once in Disparity.swift and re-run. The wiggle preview makes inversion obvious in two seconds.
- Warp: a Metal vertex grid at one vertex per 4px, vertices displaced horizontally by the disparity texture, bilinear sampling, drawn per eye. Mesh stretching covers disocclusions; no inpainting pass in v1.
- Overscan: scale both synthesized views by 2.5% and crop to frame, hiding edge stretch.

## Phase 1: Engine

Gate: drop a video onto a minimal window, get a spatial .mov out, verify it.

1. Scaffold per the architecture, tokens file stubbed with real values from the design file (you will use them in Phase 3; write them now so nothing hardcodes later).
2. Model acquisition: query https://huggingface.co/api/models/apple/coreml-depth-anything-v2-small to list files, download the mlpackage into Resources/Models, and load it on the Neural Engine (MLModelConfiguration computeUnits .all). If the download fails, go to escape hatch 2.
3. Ingest: probe duration, fps, dimensions; decode frames; passthrough audio track wiring ready for the writer.
4. DepthEstimator plus Stabilizer working: add a debug view that shows source and depth side by side for a scrubbed frame, using the silver ramp from the design file.
5. Disparity plus WarpRenderer: render synthesized left and right for one frame; run the sign convention check with the synthetic clip from TestKit.
6. Read the Apple sample writer code now, in full.
7. SpatialWriter: MV-HEVC via AVAssetWriter with the tagged pixel buffer group adaptor, two layers tagged left eye and right eye, spatial extensions set to: rectangular projection, left and right stereo eye flags, horizontal FOV 63.4 degrees, baseline 19.2mm, horizontal disparity adjustment 2.5%. Use the exact keys and units the sample uses. Audio passthrough from source.
8. Minimal shell: one window, drop target, filename label, determinate progress bar, Reveal in Finder on completion. Ugly is fine here; correct is not optional.
9. Verify: QuickTime Player on the Mac opens the export and identifies it as spatial or stereo; the spatial CLI (if installed) reports two video layers; output frame count matches source within one frame; audio plays. Print all four results to the console as a verification report.
10. Convert the synthetic clip and one real clip end to end. Checkpoint commit: phase 1 complete.

Do not block on a physical Vision Pro check; note in the README that AirDropping any golden set export to the headset and opening it in Photos is the final human verification.

## Phase 2: Judgment loop

Gate: open a file, scrub it, judge depth in four preview modes, tune it, convert with control.

1. Stage viewer with playhead scrubbing: instant frame response, no animation on scrub. Cache the depth map for the visible frame so parameter changes re-render the preview in under 100ms (re-run only Disparity and Warp on the cached depth, never the model).
2. Preview modes wired to keys 1 through 4: Source, Depth (silver ramp), Stereo (half-color anaglyph: red channel from the left view, green and blue from the right), Wiggle (hard cut alternation between left and right at 6Hz, space to play or pause).
3. Inspector: strength preset row (Soft, Standard, Deep), convergence slider with a tick at the screen plane, Advanced disclosure holding custom disparity percent, overscan, FOV, baseline, model size.
4. Queue: multiple files, per-row status and progress, selection drives the stage, sequential conversion of everything Ready, cancellation at frame boundaries that returns rows to Ready.
5. Error states: unreadable file, disk full mid-write (clean up the partial file), model missing. Plain language messages per the design file.
6. Re-run the Phase 1 verification report on an export produced through the new path. Checkpoint commit: phase 2 complete.

## Phase 3: Craft pass

Gate: the app matches RELIEF_DESIGN.md, state for state, token for token.

1. Implement every token from the design file through Tokens.swift; delete any inline color, spacing, or font that crept in during Phases 1 and 2.
2. Build the three-pane layout, toolbar, and empty state exactly as specced, including the drag-over wake state.
3. Eight states for the Convert button and queue rows as enumerated in the design file. Extend the same discipline to every remaining control.
4. Keyboard map, complete, wired through menu commands so shortcuts are discoverable in the menu bar.
5. Motion: preview crossfade 150ms ease-out, inspector collapse 200ms, determinate progress everywhere, and the signature stereo fuse on completion (vermilion and cyan title copies offset 2px for 250ms, fusing to white with a soft settle).
6. App icon: a small Swift script in TestKit draws the 1024px icon with CoreGraphics (two rounded frames offset horizontally, vermilion and cyan, screen blend fusing to near white where they overlap, on the stage color), then iconutil packs the iconset. Wire it into the asset catalog.
7. Settings scene: output folder, filename pattern. Share: NSSharingServicePicker on done rows (AirDrop is the point).
8. Golden set support: a debug menu item scans ~/Movies/ReliefGoldenSet, queues everything found, and writes a dated verification report per export.
9. QA sweep against the design file's banned list and the eight-state enumeration. Fix everything found.
10. Final build, run, convert the synthetic clip plus one real clip through the finished UI. Checkpoint commit: phase 3 complete. Push.

## Definition of done

- All three phase gates passed, all checkpoints committed and pushed
- Zero TODOs, stubs, or placeholder views in the repo
- The verification report passes on the last export
- Tokens.swift is the only place colors, spacing, radii, and type sizes are defined
- README covers: what Relief is, build loop commands, the AirDrop verification step, the sandbox decision, and where the golden set lives

## Escape hatches, ranked, use in order

1. Writer fights back: export left and right as a side-by-side ProRes .mov, mux to spatial video with the spatial CLI, and keep SpatialWriter behind a protocol so the native path can land later without touching the pipeline. The app still ships tonight's gate.
2. Model download fails: substitute any monocular depth mlpackage behind the DepthEstimator protocol and surface a model banner in the UI; the interface contract is one RGB frame in, one nearness map out.
3. Throughput misses 15 fps at 1080p: run preview at 720p while export stays full resolution, and process export frames in batches through the model.

When a hatch fires, say so in the commit message and keep moving. Blockers get solved, not reported.
