# Relief Design File

Design spec for the Relief macOS app. Phase 3 of the build implements this file exactly. Where this file and convenience disagree, this file wins.

Reference note: the Mobbin pull did not run this session (connector approval pending). When approved, run these three queries and fold findings into a revision pass: web screens "media conversion queue with per-file progress and export settings panel", web screens "video editor export dialog with format options", ios screens "before and after comparison slider in a photo editor". Until then, the anchors below carry the reference load.

## Phase 1: Job and anchor

Job to be done: "When I have a flat movie I want on the Vision Pro, I want to see and tune its depth before converting, so I can trust the export will read right on my face."

The ONE job of the main screen: judge depth. Import and export are moments. Judging is the loop, so the viewer is the hero.

Named anchors, two, with reasons:
- Apple pro app lineage (Final Cut Pro, Compressor): dark chrome that disappears behind content, a right-hand inspector for parameters, content-first stage. This is a conversion instrument on macOS; the platform's own pro apps define the dialect.
- Linear: type-led hierarchy, restraint, keyboard-first operation, one accent that earns every appearance. This supplies the modern discipline that keeps the pro-app skeleton from feeling like 2011.

Emotional read, one word: precise.

Surface: macOS 15+, single window, SwiftUI speaking the AppKit dialect (unified toolbar, inspector, menu bar, keyboard everything).

User's state on arrival: first run, curious and impatient to see the effect (the empty state must get a file on screen in one gesture). Later runs, task-focused, often batching.

## Phase 2: Information architecture and flow

Object model:
- Conversion: source URL, duration, thumbnail, status, progress, settings snapshot (frozen at export), output URL
- Settings: strength preset or custom disparity percent, convergence, overscan, spatial metadata (FOV, baseline), model size
- Preview: mode (Source, Depth, Stereo, Wiggle), playhead time, cached depth for the visible frame

The queue owns Conversions. Live Settings apply to the selected Conversion; export freezes a snapshot onto it so re-exports with new settings are a new pass, not a mutation.

Flow states, all designed or explicitly system-default:
- Empty (first launch): bespoke
- Drag-over: bespoke (stage border wakes up)
- Importing and probing (reading metadata, generating thumbnail): skeleton row
- Ready (file selected, preview live): the core state
- Converting (progress per row, queue running): bespoke
- Cancelled: row returns to Ready with settings intact
- Failed (unreadable codec, disk full, model missing): bespoke row state plus plain-language message
- Done: bespoke (signature moment, below), then Reveal and Share affordances
- Re-export: Done row plus changed settings shows a quiet "Settings changed" chip and re-enables Convert

Progressive disclosure:
- Level 0: drop zone, preset row, Convert
- Level 1: preview modes, convergence slider, scrubber
- Level 2: Advanced disclosure in inspector (custom disparity percent, overscan, FOV, baseline, model size)
- Level 3: Settings window (output folder, filename pattern)

Decision density: one primary decision per state. Ready asks "does the depth read right." Done asks nothing.

## Phase 3: Layout, grid, spatial system

- Grid: 8pt base. Spacing scale: 4, 8, 12, 16, 24, 32, 48. No values off the scale.
- Three panes. Queue sidebar 264pt (min 220, collapsible). Stage flexible, letterboxes the video on the stage color. Inspector 296pt fixed, collapsible.
- Toolbar: unified title bar. Left: Add. Center, over the stage: the preview mode segmented control (Source, Depth, Stereo, Wiggle). Right: inspector toggle.
- Density: standard (Linear), with comfortable queue rows (56pt: thumbnail 40pt, title, duration in mono).
- Focal hierarchy by size and brightness: the viewer is the largest and brightest element on screen. Exactly one filled accent control exists: Convert, full width at the inspector's bottom.
- Touch and click targets 28pt minimum for macOS controls, 44pt for anything also reachable while leaning back.

## Phase 4: Type system

- One family: SF Pro. SF Mono for every numeric readout (timecode, disparity percent, pixel values, FOV). No serif anywhere, in any state, ever (house rule).
- Scale, 1.2 ratio anchored to macOS 13pt body: 11 caption and section labels, 13 UI and body, 16 row titles and viewer overlay labels, 20 numeric readouts in the inspector, 28 empty-state headline.
- Section labels: 11pt, all caps, +0.4 tracking, 62% text color.
- Timecode and all tabular data: SF Mono, tabular figures.
- Line heights: 1.2 on labels, 1.45 on the empty-state supporting sentence.
- Hierarchy is carried by type weight and color, not boxes.

## Phase 5: Color, surface, depth

Palette strategy: neutral-dominant, single working accent, plus one paired identity moment. Dark only, and that is a decision, not a default: this is a viewing instrument, and the stage must recede. Light mode is a non-goal.

Tokens:
- stage: #101114 (off-black, never pure black)
- panel: #17181C
- panelRaised: #1D1F24
- hairline: white at 7%
- textPrimary: #F4F5F7
- textSecondary: #F4F5F7 at 62%
- textTertiary: #F4F5F7 at 40%
- accent (cyan, right-eye lineage): #29C4D6. The only color allowed on chrome: Convert fill, progress, focus rings, selection tint.
- stereoL (vermilion): #FF4F42. Appears ONLY paired with accent cyan, only where stereo is the literal meaning: the L and R eye badges in Stereo mode, the app icon, the export-complete moment. Never alone, never as chrome, never as error.
- error: #E5484D, used sparingly on failed rows and messages.
- Depth map ramp: monochrome silver, near #E8E9EC to far #26282E. Explicitly not turbo or viridis; the rainbow ramp is an AI demo tell and it is banned here.

Elevation: panels separate by tone and hairline, not shadows. One shadow in the app: the viewer's floating scrubber, y2 blur8 at 24% black.

Contrast floor: all text combinations pass WCAG AA against their surface; 13pt secondary on panel is 62% for this reason, do not lower it.

## Phase 6: Interaction, motion, signature

Eight states, enumerated for the two elements that matter most:
- Convert button: default (accent fill, #101114 label), hover (+6% lightness), focus (2pt accent ring at 40%), active (-8% lightness), disabled (panelRaised fill, textTertiary label), loading (label swaps to progress percent in SF Mono, fill animates as a left-to-right determinate sweep), success (see signature), error (shakes 2px twice, then error message below).
- Queue row: default, hover (panelRaised), focus ring, selected (accent at 12% fill plus 2pt leading accent bar that encodes selection, a state, not decoration), converting (thumbnail dims, progress ring over it), done (checkmark chip), failed (error chip).

Keyboard map (Linear anchor, non-negotiable):
- 1 2 3 4: preview modes
- Space: play or pause the wiggle
- Left and Right arrows: step frames; Shift steps 1 second
- Cmd O: import, Cmd Return: convert selected, Cmd Delete: remove from queue
- Cmd I: toggle inspector

Motion, each with a stated job:
- Preview mode switch: 150ms ease-out crossfade (feedback)
- Inspector collapse: 200ms ease-out (spatial continuity)
- Progress: determinate only, no indeterminate spinners once conversion starts (status)
- Scrubbing: zero animation, instant frame response (speed is the affordance)
- Wiggle mode: hard cut alternation at 6Hz between synthesized left and right (the depth judgment tool itself; no crossfade, crossfade kills the effect)

Signature move, the stereo fuse: when a conversion completes, the row title splits into a vermilion copy and a cyan copy offset 2px left and right for 250ms, then fuses back to a single white title with a soft settle. The anaglyph identity, spent exactly once, at the only moment that has earned it. Same motion at 1024px scale is the app icon's story: two offset rounded frames, vermilion and cyan, fusing to near-white where they overlap, on stage #101114.

Microcopy (plain human voice, no marketing):
- Empty state headline: "Drop a movie here."
- Empty state support: "Relief reads its depth and writes a spatial video your Vision Pro plays natively."
- Convert button: "Convert" (never Submit)
- Failed decode: "Couldn't read this file. Relief speaks H.264, HEVC, and ProRes."
- Done row secondary action: "Reveal in Finder"
- Wiggle mode hint, shown once: "If the wiggle looks wrong, the export will too. Tune Strength until it reads."

## Banned in this app

Purple or indigo anywhere, pure #000 or #FFF, glassmorphism, decorative gradients, indeterminate spinners during conversion, rainbow depth maps, emoji in UI, serif faces, drop shadows as separators, rounded-corner inflation (radius vocabulary is 6 for controls, 10 for panels and thumbnails, nothing larger).

## Materials, and the glassmorphism line

The original banned list said "glassmorphism". That was aimed at the 2021 trend:
frosted cards floating on a saturated gradient, blur used as decoration. That
ban stands.

Native macOS vibrancy is a different thing and is now used deliberately. The
sidebar takes `NSVisualEffectView` with the `.sidebar` material and behind
window blending, because every macOS app with a sidebar does and a flat fill
there is the loudest signal an app was not built for this platform. The
inspector takes a within window material, as a parallel panel that does not
block the flow. Toasts and the scrubber take the HUD material, because they
genuinely float.

Three rules keep it honest:

- **The stage never takes material.** Depth is judged against a dead field, not
  against the user's wallpaper. The stage stays #101114 and is the darkest
  thing on screen.
- **Material weight encodes hierarchy.** Heaviest on the structural region
  (sidebar), lighter on things that float. Light translucent surfaces are never
  stacked on each other.
- **Every material has a solid fallback.** Reduce Transparency swaps in the
  original flat fills; Increase Contrast adds a defined border. Translucency
  without a fallback is an accessibility failure, not a style.

## Self-critique against the anchors

- Job clarity 5: a stranger sees a video, a depth map toggle, and one Convert button.
- IA 4: object model is clean; re-export state needs a real pass once built.
- Progressive disclosure 5: metadata and model size are two levels deep, exactly where Final Cut would put them.
- Grid and rhythm 4: three-pane with a fixed scale; earn the 5 in implementation.
- Type discipline 5: one family, one mono, one scale.
- Color discipline 5: one working accent with a written rule for the second.
- Contrast 4: verify the 62% secondary on panel in code, adjust up if it misses AA.
- Interaction completeness 4: eight states specced for the two core elements; extend the pattern to every control during Phase 3.
- Motion intent 5: every animation has a job written next to it.
- Edge cases 4: failed and empty are bespoke; disk-full path gets designed in build.
- Microcopy 5: it has a voice and zero filler.
- Signature move 5: the stereo fuse is ownable and semantically true.
- Distance from generic 4: the skeleton is a known pro-app pattern on purpose; the identity system (paired accent rule, silver depth ramp, wiggle-first judging) is what nobody else ships.
