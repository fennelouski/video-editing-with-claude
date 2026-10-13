# style_guide.md

**The correction log. This is where the pipeline learns.**

`taste_principles.md` is the standing specification — what we already know.
This file is the running record of every time a render was wrong and why.
Its whole purpose is that **the same mistake never gets made twice.**

---

## How this works

1. A render goes out for review (Stage 6 auto-check, or a human watching it).
2. Anything that gets sent back is logged here **immediately**, as a new entry, using the
   schema below. Log it even if the fix is obvious. Especially if the fix is obvious.
3. Before generating any graphic, the pipeline **reads this entire file** and treats every
   `ACTIVE` entry as a binding constraint, ranked above its own defaults.
4. When the same correction is logged **twice**, it stops being a correction and becomes a
   rule: promote it into `taste_principles.md`, then mark the entries here `PROMOTED`.
5. Entries are never deleted. Superseded ones get a dated note so old renders stay explainable.

### Entry schema

```
### [ID] — <short title>
- **Date:**        YYYY-MM-DD
- **Video / shot:** <project> · <timecode or graphic ID>
- **Source:**      human | stage6-auto
- **Status:**      ACTIVE | PROMOTED | SUPERSEDED
- **Category:**    typography | color | texture | motion | layout | audio | grade | pacing | asset | copy
- **What was wrong:**   <observable defect, not a feeling>
- **Why it was wrong:** <which principle it violated, or what it made the video look like>
- **The rule going forward:** <imperative, testable, specific>
- **Auto-check:**  <how Stage 6 can detect this, or NONE if it needs a human eye>
```

### Writing a good entry

The rule line has to be **testable**. "Make it feel warmer" teaches nothing.
"Backgrounds behind marker type use `--oat`, never `--kraft` — kraft doesn't leave enough
contrast for a 4 px marker stroke" is a rule the pipeline can actually follow.

If a correction can't be written as a testable rule, it belongs in **Open questions** at the
bottom instead, until it can.

---

## Active rules

> Seeded from the first pass on `taste_principles.md`. Everything below §Log is empty until
> the first review — that's expected.

### [S-001] — AI b-roll is out of scope for this channel
- **Date:** 2026-08-11
- **Video / shot:** project-wide
- **Source:** human
- **Status:** ACTIVE
- **Category:** asset
- **What was wrong:** The original pipeline spec had a stage that generated missing b-roll with
  a text-to-video model.
- **Why it was wrong:** The channel's entire premise is that it is not machine-made. Generated
  footage is the one thing that cannot be rescued by grading or texture — it is recognizable,
  and one shot of it discredits the other nineteen minutes.
- **The rule going forward:** The pipeline never generates footage or imagery. When an asset is
  missing, Stage 4 produces a **build sheet and shot list** for her to make or film. A missing
  asset blocks the render; it does not get filled in.
- **Auto-check:** Stage 4 fails the run if any planned asset has no file in `assets/` or `footage/`.

### [S-002] — Silence trimming has a floor
- **Date:** 2026-08-11
- **Video / shot:** project-wide
- **Source:** human
- **Status:** ACTIVE
- **Category:** audio
- **What was wrong:** Default auto-editors cut every pause to zero.
- **Why it was wrong:** Removing all breath is the single most recognizable signature of a
  machine edit. It sounds unnatural before a viewer can say why.
- **The rule going forward:** Never trim a gap below **120 ms**; target **150 ms** of breath at
  sentence boundaries and **250 ms** at paragraph/idea boundaries. Room tone runs under every cut.
- **Auto-check:** Stage 2 enforces `BREATH_FLOOR_MS`; Stage 6 re-measures the exported audio.

### [S-003] — Never `#000000` or `#FFFFFF` in the graphic layer
- **Date:** 2026-08-11
- **Video / shot:** project-wide
- **Source:** human
- **Status:** ACTIVE
- **Category:** color
- **What was wrong:** Default text color and default shadow color are pure black; default
  paper is pure white.
- **Why it was wrong:** Neither value exists on paper or in a lit kitchen. They make a warm
  frame read as computer-generated faster than any other single choice.
- **The rule going forward:** Text is `--walnut #4A3C2E`. Paper is `--bone #F2EDE1`. Shadows are
  `rgba(74,60,46,·)`. Highlights roll off at 90–94 IRE.
- **Auto-check:** Stage 6 check #9 — sample the graphic layer for pure values.

### [S-004] — Handwriting font must rotate its alternates
- **Date:** 2026-08-11
- **Video / shot:** project-wide
- **Source:** human
- **Status:** ACTIVE
- **Category:** typography
- **What was wrong:** N/A — pre-emptive, logged during font construction.
- **Why it was wrong:** Identical repeated glyphs are the defining tell of a fake handwriting
  font. `LETTER` with two matching `T`s reads as a font instantly.
- **The rule going forward:** Ship 3–5 drawn alternates for high-frequency glyphs and digits,
  wired to `calt`. Every template sets `font-feature-settings: "calt" 1`. Never faux-bold.
- **Auto-check:** Template lint — fail any CSS using `--font-marker` without `calt` enabled.

---

### [S-005] — Captions are native Final Cut objects, not a burned layer
- **Date:** 2026-08-11
- **Video / shot:** project-wide
- **Source:** human
- **Status:** ACTIVE
- **Category:** typography
- **What was wrong:** The first spec had the pipeline burning captions into an alpha layer with
  a word-level rust highlight driven by the WhisperX timings.
- **Why it was wrong:** Finishing happens in Final Cut. A burned caption layer is a decision
  she can't revise — a typo means a re-render, and the text isn't searchable or editable.
- **The rule going forward:** Stage 5 writes an `.itt` sidecar; captions are real FCP caption
  objects. The pipeline still decides the **line breaks** (2 lines, ≤36 chars) so they break on
  sense rather than FCP's auto-wrap. Accepted cost: no word-level highlight — FCP has no
  karaoke fill. Reversible via `CAPTION_MODE = "burn"` in `config.py`.
- **Auto-check:** NONE — verify by eye on the first video.

### [S-006] — The pipeline hands off a timeline; it never flattens a master
- **Date:** 2026-08-11
- **Video / shot:** project-wide
- **Source:** human
- **Status:** ACTIVE
- **Category:** asset
- **What was wrong:** Stage 5 originally stitched everything with ffmpeg into a finished
  `master.mp4` — overlays composited, captions burned, audio mixed.
- **Why it was wrong:** She edits in Final Cut. A flattened master throws away every decision
  she might want to change and makes the pipeline the last word instead of the first draft.
- **The rule going forward:** Stage 5 renders each graphic as its own ProRes 4444 alpha layer
  and emits an FCPXML 1.13 with the cut timeline, the layers as connected clips on lane 1, cue
  markers, and chapter markers. Stage 6 reviews what she exports *back out* of FCP.
- **Auto-check:** `fcpxml.validate()` runs on every generated file; Stage 5 fails loudly if the
  document is off the frame grid or references missing media.

### [S-007] — The timebase is 23.976, everywhere
- **Date:** 2026-08-11
- **Video / shot:** project-wide
- **Source:** human
- **Status:** ACTIVE
- **Category:** motion
- **What was wrong:** The pipeline assumed an integer 24 fps.
- **Why it was wrong:** The T3i, R100, and RP all record "24p" as 23.976 — no Canon consumer
  body offers exact 24.000 in an NTSC region. A 24.000 timeline against 23.976 media drifts
  audio progressively across a long take, and every FCPXML time value lands off the frame grid,
  which makes Final Cut either reject the import or shift clips by a frame.
- **The rule going forward:** `FPS_NUM/FPS_DEN = 24000/1001` throughout. All timing arithmetic
  happens in **integer frames** and converts to seconds or rationals exactly once, at the edge.
  Never write a float frame rate into an ffmpeg or FCPXML argument.
- **Auto-check:** `fcpxml.validate()` rejects any time value that isn't a multiple of 1001/24000.

### [S-008] — The T3i needs a per-body correction before the channel LUT
- **Date:** 2026-08-11
- **Video / shot:** project-wide
- **Source:** human
- **Status:** ACTIVE
- **Category:** grade
- **What was wrong:** N/A — pre-emptive, logged when the camera bodies were confirmed.
- **Why it was wrong:** The T3i is a 2011 8-bit body. Its colour science is visibly greener and
  flatter than the R100/RP, and applying one channel LUT across all three will make cuts
  between cameras read as a mistake — which undermines the "professionally shot" half of the
  thesis far more than any graphic does.
- **The rule going forward:** Grade in two steps — a per-body matching correction first, then
  the shared channel LUT. Shoot a grey card and colour checker on **every** body at the top of
  every session; match to the RP, which has the best latitude. The T3i's 12-minute clip limit
  means long takes arrive segmented, so Stage 1 must handle multi-part sources.
- **Auto-check:** NONE — needs a human eye on an A/B cut.

### [S-009] — Script discovery is allowlist + evidence, never a denylist
- **Date:** 2026-08-11
- **Video / shot:** project-wide · `scripts/stage3_plan.py:find_script()`
- **Source:** human (found during Claude Code phase 0)
- **Status:** ACTIVE
- **Category:** asset
- **What was wrong:** `find_script()` fell back from `script/` to the repo root and excluded
  documents with a hardcoded denylist of three filenames. Every other root document was a
  candidate, and alphabetical order meant `CLAUDE.md` was selected as the narration script.
- **Why it was wrong:** A denylist is open by default — it silently degrades every time a
  document is added to the project, and it degrades *toward* planning graphics off the wrong
  file. That violates "failures are loud and actionable; never silently substitute a default."
  It was harmless only because no root document happened to contain a `[[GFX: …]]` marker yet,
  and `PROMPT_claude_code.md` now documents that syntax.
- **The rule going forward:** `script/` is the canonical and only location for the annotated
  script. Auto-discovery scans `script/` only. If `script/` is empty, scan the root for files
  **containing at least one valid cue marker** — and if any are found, **stop with an error
  naming them** and telling her to move the file into `script/`. Never plan off a root file.
  A path passed explicitly on the command line is always trusted and always wins. Discovery
  requires evidence; an explicit instruction does not.
- **Auto-check:** Regression test — a root document containing a `[[GFX: …]]` marker must cause
  Stage 3 to exit non-zero naming that file, and must never produce a plan from it.

### [S-010] — Phase boundaries land on the step grid, not just the samples
- **Date:** 2026-08-11
- **Video / shot:** project-wide · `scripts/stepclock.py:pose_at()`
- **Source:** stage6-auto (caught by the Phase 1 test suite, before any render)
- **Status:** ACTIVE
- **Category:** motion
- **What was wrong:** `pose_at()` quantised the frame it *sampled*, but each phase helper
  counted from the start of its own phase. `hold_frames` came from `frames_for()` and was odd
  roughly half the time, which flipped the parity of everything after the hold: with a 47-frame
  hold, the entire pull-off animated on frames 59, 61, 63. The entrance never showed it because
  `PLACE_FRAMES[1]` is 10 and every `stagger_offset` is a multiple of 4 — both even, by luck
  rather than by design. Quantising the sample alone then exposed a second failure: with an
  unaligned hold, `out_elapsed` only ever took odd values, so the exit never reached opacity 0
  and the graphic vanished at full opacity partway through being pulled off.
- **Why it was wrong:** Non-negotiable 6 and §5.1 — a graphic moving on an odd frame breaks the
  stop-motion illusion and the composition reads as After Effects. The hard pop at the end of an
  unaligned hold is the §5.3 failure as well: objects are pulled off, never cut mid-gesture.
- **The rule going forward:** Every phase length is rounded **up** onto the step grid before
  use, via `StepClock.on_step()`. Holds come from `StepClock.hold_frames()` and nowhere else,
  so `pose_at()` and Stage 5's sequence length cannot disagree. Rounding is up rather than to
  nearest because §5.4 hold is a floor — `frames_for()` rounds to nearest and turned a 1.6 s
  minimum into 38 frames (1.585 s), under the floor the formula had just set. Promoted into
  `taste_principles.md` §5.1.
- **Auto-check:** `tests/test_stepclock.py::test_pose_only_changes_on_even_frames` and
  `::test_exit_completes_invisible`, both parametrised over odd *and* even hold lengths — an
  even-only sweep hides the entire defect class.

### [S-011] — Alpha is premultiplied for every resample, and the grain pass runs in float
- **Date:** 2026-08-11
- **Video / shot:** project-wide · `scripts/stage5_composite.py`
- **Source:** stage6-auto (caught by the Phase 1 test suite, before any render)
- **Status:** ACTIVE
- **Category:** color
- **What was wrong:** The graphic layer contained `#000000` pixels — §12 check 9 and
  non-negotiable 5. Two independent causes. First, `fit_to_slot()` and `apply_transform()`
  resampled straight RGBA. A matted cutout carries RGB 0 under its transparent region after a
  PNG round-trip, and the negative lobes of LANCZOS and BICUBIC pull those zeros into the
  feathered edge. Second — and it survived the first fix — `grain_pass()` used
  `ImageChops.multiply` and `Image.blend`, which truncate rather than round, and truncate
  twice: a channel at 1 multiplied by the ~0.98 the grain actually applies came back as 0.
- **Why it was wrong:** Pure black does not exist on paper, and it lands on exactly the torn
  and cut edges §1.3 says to preserve — a dark fringe reads as a bad matte, which is the
  vector-crisp tell in a different costume. Measured over `--bone` the error was small (max
  4/255), so this would never have been caught by eye; it needed a numeric check.
- **The rule going forward:** Every resample of an image with alpha goes through
  `resize_rgba()` / `rotate_rgba()`, which premultiply in **float** — Pillow's built-in
  `RGBa` mode stores the premultiplied value as uint8 and its round-trip measured
  bit-identical to no fix at all. Alpha is quantised *before* the division so a nearly
  transparent pixel cannot amplify to `#FFFFFF`. Values that land outside what an 8-bit
  channel can honestly express are moved to the nearest legal code (1 and 254), while a
  channel that is genuinely 0.0 or 1.0 is left alone so real artwork violations still
  surface. `grain_pass()` runs in float for the same reason.
- **Auto-check:** `tests/test_stage5_composite.py::test_no_pure_black_or_white_in_the_graphic_layer`
  asserts at alpha ≥ 1, not at a "visible" threshold — a threshold would have to be chosen to
  accommodate whatever fringe the compositor produced, which is fitting the test to the code.
  `::test_resampling_matches_a_float_reference` compares against an independent premultiplied
  reference, and `::test_grain_pass_never_drives_a_pixel_to_black` covers the second cause.

### [S-012] — The matte boundary is not the optical edge
- **Date:** 2026-08-11
- **Video / shot:** project-wide · `scripts/tools/sheet.py`
- **Source:** human (found building edge extend, phase 2)
- **Status:** ACTIVE
- **Category:** asset
- **What was wrong:** A lens renders a cut edge across several pixels. A matte derived from
  colour distance puts its boundary where the capture is roughly half cardboard and half
  seamless — so pixels measuring 0.504, midway between seamless 0.46 and kraft 0.76, were
  being stored at **full alpha**. That grey blend then shows as a rim over any background,
  on any monitor, no matter who resamples it downstream.
- **Why it was wrong:** It is the inverse of [S-011] — a *visible* defect that breaks no rule.
  Nothing in §12 measures it, and no compositor fix can reach it, because the wrong value is
  baked into the extraction. Shrinking the matte would fix it and eat fibre, which §1.3 exists
  to protect.
- **The rule going forward:** The matte stays generous. `edge_extend` rewrites colour in a thin
  ring, sampling from an **eroded interior** so it bleeds cardboard outward rather than seamless
  inward. Geometry is never resampled and the interior is never touched — "unmodified
  extraction" in §1.3 means the *interior* is unmodified, which is what the tests now assert.
- **Auto-check:** The ring rewrite must always move colour **away** from the measured seamless.
  If edge extend ever bleeds background inward the sign flips and the test fails. This is the
  assertion that matters; the rest are bookkeeping.

### [S-013] — Record the seamless colour every session
- **Date:** 2026-08-11
- **Video / shot:** project-wide
- **Source:** human
- **Status:** ACTIVE
- **Category:** asset
- **What was wrong:** N/A — pre-emptive, follows from [S-012].
- **Why it was wrong:** Every matting decision is made relative to the backdrop. If the seamless
  value is inferred per-sheet rather than measured, it drifts with exposure and white balance,
  and the edge-extend direction check in [S-012] loses its reference.
- **The rule going forward:** The grey card frame that §1.2 already requires also establishes the
  seamless value. Record it in a sidecar next to the sheet and pass it to the segmenter
  explicitly — never infer it from the image being matted.
- **Auto-check:** Segmenter fails if no seamless value is supplied and none is recorded.

### [S-014] — Backdrop distance is measured along the ray, and floored by a measured shadow depth
- **Date:** 2026-08-11
- **Video / shot:** project-wide · `scripts/tools/sheet.py`
- **Source:** human (phase 3)
- **Status:** ACTIVE
- **Category:** asset
- **What was wrong:** Adopting the measured backdrop reference from [S-013] immediately merged
  two pieces into one. `background_distance` used absolute difference, so the cast shadow that
  §1.2 *guarantees* — pieces sit 10 mm off the backdrop on foam tape — read as a dark piece, and
  the shadow bridging two neighbours joined them. It had been hidden only because the previously
  inferred reference came from the sheet border, which already sat partway into shadow.
- **Why it was wrong:** Absolute distance treats "darker" and "different" as the same thing.
  They are not: a shadow is the backdrop **scaled down**, so it lies on the ray through the
  backdrop colour, while a piece of a different material lies off it.
- **The rule going forward:** Measure distance **along the ray through the backdrop colour**.
  Shadow and lighting falloff then measure ~0; materials sit clear.

  **Plus a floor, because the ray alone is not sufficient.** Any near-neutral dark subject also
  lies on that ray — heavy walnut marker fill, a charcoal card, grey chipboard — and would be
  classified as very deep shadow and eaten. Real shadow depth is bounded by the lighting ratio
  §1.2 specifies; a marker fill is far darker than any shadow that lighting can cast. So a pixel
  is background only if it is on the ray **and** no darker than the deepest plausible shadow.
- **The floor is measured, never guessed.** Record it in the same frame as the grey card and the
  seamless value, from a piece deliberately casting a shadow. Guessing a constant would put a
  lighting-dependent number in code, which is what [S-013] existed to prevent.
- **Auto-check:** A fixture containing a near-neutral dark piece adjacent to a shadowed gap must
  segment as two pieces, with the dark piece's interior intact.

### [S-015] — Off-axis capture is detected and refused, not corrected
- **Date:** 2026-08-11
- **Video / shot:** project-wide
- **Source:** human (phase 3)
- **Status:** ACTIVE
- **Category:** asset
- **What was wrong:** The §1.2 ≥2400 px long-edge check measures *apparent* pixels. A piece shot
  a few degrees off-axis has an apparent long edge shorter than its true one, so it can pass the
  check while being undersized — or fail it while being fine.
- **Why it was wrong:** The tempting fix is a camera-side homography that corrects for the tilt.
  That is the wrong instinct twice over: §1.3 forbids resampling cutout geometry, and a
  perspective-distorted photograph of flat artwork is *already* wrong — a rectangle shot
  off-axis is a trapezoid, and no correction restores the fibre detail the foreshortened edge
  never resolved.
- **The rule going forward:** §1.2 already requires the sensor plane parallel to the table. The
  homography's job is to **measure deviation from square and fail the capture** when it exceeds
  tolerance, naming the correction ("camera is ~3° off-axis, level it and reshoot"). It computes
  true dimensions for the size check. It never rewrites a pixel.
- **Auto-check:** Camera-path deskew must return a measurement type, not an image. If it cannot
  return pixels, the mistake is unrepresentable rather than merely discouraged.

### [S-016] — A placeholder that validates is worse than a field left empty
- **Date:** 2026-08-11
- **Video / shot:** project-wide
- **Source:** human (phase 4, generalised from the molecule solver)
- **Status:** ACTIVE
- **Category:** asset
- **What was wrong:** `molecules/water.json` shipped with `reviewed_by: "unreviewed"`. That is a
  non-empty string, so it passed validation and rendered happily. The shipped example — the file
  most likely to be copied as a template and least likely to be read closely — was the shortest
  path to an unreviewed molecule reaching a render.
- **Why it was wrong:** An empty field fails loudly. A placeholder *satisfies* the check while
  carrying none of the meaning the check exists to enforce, and it does so while looking
  complete. This defeats `ESCALATE_TO_HUMAN` at exactly the point it matters.
- **The rule going forward:** Any field whose purpose is to record that a human did something
  must reject placeholder values by name — `unreviewed`, `TODO`, `TBD`, `changeme`, `xxx`,
  `placeholder`, `n/a`, and the empty string. Shipped examples must be **unable to run**, and a
  test must assert that.

  **This applies to `style_guide.md` itself.** Stage 6 appends auto-generated entries whose
  "rule going forward" line reads *"write this as a testable rule before the next run."* Stages
  3–5 treat every `ACTIVE` entry as binding, so an unfilled entry is a constraint that
  constrains nothing while appearing to. Any stage that reads this file must refuse to run — not
  warn — while an `ACTIVE` entry still carries the placeholder, naming the entry IDs. An entry
  without a testable rule teaches the pipeline nothing, and the README has said so since the
  first commit; nothing enforced it.
- **Auto-check:** A loader-level scan for placeholder text in `ACTIVE` entries, plus a test that
  every shipped example file fails validation.

### [S-017] — Validate against the importer's own schema, not our reading of it
- **Date:** 2026-08-11
- **Video / shot:** project-wide · `scripts/fcpxml.py`
- **Source:** human (phase 5)
- **Status:** ACTIVE
- **Category:** asset
- **What was wrong:** Every connected clip the pipeline ever emitted carried `role="…"` on an
  `asset-clip`. There is no bare `role` attribute — `asset-clip` takes `audioRole` and
  `videoRole`. Our hand-written `validate()` passed it cleanly because it checked what we
  believed the format to be.
- **Why it was wrong:** It would have surfaced as *"The file could not be imported"* on the
  first real handoff, with nothing indicating which of a hundred attributes was at fault — the
  worst possible failure mode, arriving at the worst possible moment.
- **The rule going forward:** Final Cut ships the authoritative DTD for every FCPXML version it
  reads, at `Interchange.framework/Resources/FCPXMLv1_13.dtd`. Validate against it. It is the
  importer's actual contract, machine-readable, and needs no GUI and no footage. Where an
  authoritative schema exists on disk, never substitute our own model of it.
- **What the DTD still cannot check:** format names, media resolution against the declared
  format, and whether `file://` URLs resolve. Those are semantic and need a real import.
- **Auto-check:** `dtd_problems()` runs in `validate()` wherever FCP is installed, across both
  aspects. It returns `None` when FCP is absent — not `[]`. See the convention in `CLAUDE.md`.

### [S-018] — The settle overshoot was never happening
- **Date:** 2026-08-12
- **Video / shot:** project-wide · `scripts/stepclock.py:_step_ease()`
- **Source:** stage6-auto (found deriving the foley contact frame, phase 7)
- **Status:** ACTIVE
- **Category:** motion
- **What was wrong:** §5.3 asks for "a 2-frame settle overshoot" so a placed piece looks set
  down. `_step_ease` claimed in its own docstring to peak at 1.06 and in fact peaked at
  **1.0009** — an overshoot of 0.036 px at a 40 px rise. Its two terms could never combine
  above 1: the sine term peaks near p=0.3 while the base curve is still at 0.66, and by the
  time the base approaches 1 the `(1-p)` factor has crushed the sine to nothing. Found only
  because the foley hit needed the frame at which a piece *touches the table*, and that frame
  kept resolving to the end of the animation.
- **Why it was wrong:** Every graphic the pipeline has ever placed glided smoothly to rest.
  That is the eased motion §5.5 bans outright and §0 names as the thing that reads as After
  Effects — the exact failure the whole stop-motion treatment exists to avoid, shipping
  unnoticed because the docstring asserted the behaviour the code did not have.
- **The rule going forward:** The settle is asserted on the **rendered position**, not on the
  easing function: at least one stepped frame must sit past rest, by more than 1 px and less
  than 15% of the rise, and the placement must resolve to exactly rest. A comment describing
  motion is not evidence that the motion happens.
- **Auto-check:** `tests/test_stepclock.py::test_the_settle_actually_overshoots` and
  `::test_the_settle_resolves_to_exactly_rest`.

### [S-019] — §5.3 fixes the settle's duration but not its amplitude
- **Date:** 2026-08-12
- **Video / shot:** project-wide · `taste_principles.md` §5.3
- **Source:** human (raised fixing [S-018])
- **Status:** ACTIVE
- **Category:** motion
- **What was wrong:** §5.3 says "a 2-frame settle overshoot" and stops there. Tuned to overshoot
  for exactly one step — 2 frames, the smallest a graphic stepping on 2s can express — the piece
  passes rest by 0.45 px at the specified 40 px rise. That is invisible at 1080p, so satisfying
  the stated duration defeats the stated purpose: "so it looks set down, not slid in".
- **Why it was wrong:** Not a code defect — a spec that constrains one dimension of a motion and
  leaves the one that decides whether it reads at all unspecified.
- **The rule going forward:** `SETTLE_OVERSHOOT` is tuned for **visibility first**: ~2 px past
  rest across two steps, the closest thing to §5.3's stated intent that can actually be seen.
  If the amplitude is ever specified, it wins and this constant follows it.
- **Auto-check:** The bounds in [S-018]'s test encode the range; a value outside it fails.

---

## Log

*Entries append here, newest first. Empty until the first review pass.*

<!-- NEW ENTRIES GO DIRECTLY BELOW THIS LINE -->

---

## Recurring-correction tracker

When a count hits **2**, promote the rule into `taste_principles.md` and mark the entries
`PROMOTED`.

| Correction theme | Count | Status |
|---|---|---|
| *(none yet)* | — | — |

---

## Open questions

Things noticed but not yet expressible as a testable rule. Revisit each review cycle.

- How long can a single cardboard diagram hold before it stops being interesting? Suspect the
  §5.4 formula is too generous for diagrams that assemble piece by piece — the assembly itself
  buys attention. Measure on video 1 and refine.
- Does the stop-motion step read as intentional at 9:16, or does phone playback smoothing
  fight it? Test a clip before committing the vertical cuts.
- Whether chapter cards should use the marker font or Fraunces. Try both on video 1 and pick
  one for the channel.

- **Two-exposure difference matting — pending her agreement, because it changes the table
  workflow.** [S-012] fixes the *colour* in the edge band; the *alpha* there is still wrong.
  A fibre wisp genuinely covers part of a pixel and should carry partial alpha, but a
  colour-distance matte can only give it full alpha or none.

  With a known backdrop, alpha is exactly solvable rather than estimated: shoot each setup
  twice, once with the backdrop lit and once with it unlit while the piece stays lit from
  above, and `α = (O_lit − O_unlit) / (B_lit − B_unlit)` per channel. No thresholding, no
  hysteresis, no erosion — and fibre comes out with the partial coverage it actually has.

  The cost is one extra exposure per setup, not per piece, and nothing moves between the two
  frames. She is already shooting 4–6 variants per piece, so this is a backdrop-light toggle
  rather than a new category of work. Worth testing on the first sheet before committing.
  If it holds up, it supersedes most of the matting logic rather than adding to it.

---

## Per-video notes

### Video 001 — Yeast: the chemistry home bakers miss
*Status: pre-production.*

- Subject-matter accuracy is reviewed by her, never by the pipeline. Any number, temperature,
  or mechanism in a graphic is escalated, not auto-filled.
- Known graphics needed: yeast cell (parent + budding), glucose → ethanol + CO₂ pathway,
  proofing temperature gauge, fermentation timeline, dead-starter vs. active-starter comparison.
- Known failure b-roll to shoot: water too hot killing the starter, a dense under-proofed loaf,
  an over-proofed collapse. Shoot the failures before shooting the successes — they're harder
  to reproduce on demand.

---

### [S-020] · ACTIVE · rough cut

**Defect.** The first cut of real footage was 37 clips, eleven of them under half a second, and
opened on 21 seconds of nobody speaking. The stage was measuring the *audio* and finding it
clean — the joins were seamless, the short clips were room tone. But the picture jump-cuts at
every one of them, because each fragment is a different source moment and therefore a different
camera position. Nathan's word for it was "jumpy and uncomfortable", and he was right.

Four separate causes, all of them the same mistake in different clothes: judging a decision by
one of its consequences rather than by what the viewer receives.

**Rules.**

1. **Dead air includes the head and the tail.** Looking only *between* words leaves whatever sits
   before the first one and after the last. Trim both to `BREATH_PARAGRAPH_MS`.

2. **Retakes cluster, they do not pair.** She does a line five or six times, each slightly
   different, so a pairwise test at a high threshold catches the identical pairs and ships the
   rest. Group transitively at `RETAKE_SIMILARITY`, and treat a line that is the exact head or
   tail of a nearby one as the same line — a run-up or a trail-off is contiguous with one end of
   the full take, which is what distinguishes it from a phrase that merely shares vocabulary.
   Overlap ratio cannot see this: "thousands of years ago." scores 0.40 against the ten-word
   line it broke off from.

3. **Keep the last *complete* attempt, not the last attempt.** She trails off on the final try
   more often than not. Within a cluster, anything under `RETAKE_COMPLETE_FRACTION` of the
   fullest member is a fragment, not a take.

4. **A breath is never its own shot.** A pause that survives between two takes is a third camera
   position for five frames. Give it to the take it leads into by starting that take earlier —
   same shot, no extra cut — and stop the extension at the last spoken word, or it drags in the
   final word of the discarded attempt before it.

5. **A time target tightens pauses and nothing else.** `--target SECONDS` may clamp breath toward
   the [S-002] floor and never past it. If the target can only be met by cutting her lines, the
   stage reports the shortfall. A number in a brief does not outrank her performance.

**Result on `MVI_0016.MOV`:** 176.1 s → 46.8 s, 37 clips → 17, shortest clip 0.21 s → 1.04 s,
clips under half a second 11 → 0.

---

### [S-021] · ACTIVE · rough cut

**Defect.** The cut shipped in [S-020] passed every check on the stage — clip counts, durations,
the frame grid, the breath floor, 493 tests — and its last third was unusable. It said "the
earliest records that we have are from Egypt" verbatim twice, said "we do know that there are
records" three times, stopped one sentence dead at "and there's other records from", and ended
the video on a comma. Nathan read it; I never did.

Every acceptance criterion on this stage measured the *shape* of the edit. None of them measured
whether it made sense out loud, which is the only thing a viewer receives. A cut can be perfectly
formed and say nothing.

**Rules.**

1. **Read the cut.** Stage 2 reconstructs the script from the EDL, prints it, writes
   `<clip>.script.txt`, and runs `read_through()` on it every run. A verbatim run repeated
   between adjacent lines, or a line ending without terminal punctuation, is a **failure** —
   non-zero exit, not a warning. Nothing downstream should treat an unreadable cut as finished.

2. **Detect restarts by verbatim overlap, not by similarity.** She restarts mid-passage, so two
   attempts share fourteen consecutive words and still score 0.56 whole-sentence. The run must
   also be at least half the shorter line: six words alone matches "but we do know that", which
   opens five unrelated sentences in this clip.

3. **Completeness is punctuation, not length.** A line that does not end on `.`, `?` or `!` is
   one she trailed off on, however long it is. An ellipsis is trailing off.

4. **A passage with no finished attempt has no usable take — drop all of it.** Falling back to
   "keep the last member" when nothing in a cluster was completed is what closed the first cut
   on a five-word tail of an abandoned sentence. She has to say it again; the rough cut should
   surface that rather than paper over it.

5. **A line she trailed off on and then talked past is an abandoned take**, whether or not
   anything nearby resembles it closely enough to cluster. Not the last line on the tape — that
   may simply be where the camera stopped.

**Result on `MVI_0016.MOV`:** 46.8 s → 31.1 s, and the six surviving lines read start to finish
without a repeat, a dangling clause, or a missing full stop.

---

### [S-022] · ACTIVE · audio

**Defect.** The music bed level and the band it is measured in were defined in
`handoff/build_video.py`, so laying a bed anywhere else meant copying the constant. Copying
`MUSIC_UNDER_DB` without `MUSIC_BAND` reproduces the original failure exactly: a full-band match
sets the gain from bass a phone or laptop never reproduces, and on a track that is 85% sub-200 Hz
it put the audible part 7 dB below where the number claimed. Nathan reported he could not hear
the music three times while the measurement said it was correctly placed.

**Rule.** `scripts/music.py` owns the level, the band, the high-pass and `bed_gain()` together.
Anything laying a bed imports all four. A stated dB figure without the band it was measured in
is not a specification.

**Second defect, found while adding a bed to the stage 2 preview.** `alimiter` auto-levels its
output unless given `level=false`. Used as a safety ceiling it silently acted as a normaliser,
putting the preview 2 dB over the channel target and its true peak 1.2 dB *over* the ceiling it
was there to enforce. Its limit is also set half a dB under the −1.5 dBTP the §12 rubric asks
for, because AAC overshoots what the limiter hands it and the number that matters is the one in
the delivered file, measured after encoding.

**Third.** A bed under a rough cut is measured against the *cut* voice, never the source. This
cut is 82% shorter than its source and drops the loudest run-ups; a gain derived from the
original lands in the wrong place.

Music is preview-only and never reaches the FCPXML — where a bed sits, and under which take, is
a timeline decision [S-006].

---

### [S-023] · ACTIVE · audio

**Defect.** Asked to compress the dialogue to bring the level up, I reached for a compressor
before measuring whether there was anything to compress. There was not: the first real clip
measures **3.6 LU loudness range before any processing**, against the 6–8 LU a dialogue
compressor exists to pull in. She is an unusually even speaker. A −18 dB threshold took the range
to 2.5 LU and handed the level straight back through makeup gain — squashing a track that had
nothing to squash, which is exactly what §8 means by "never over-processed".

**Rules.**

1. **Measure the range before setting the threshold.** A compressor is sized to the material.
   `COMP_THRESHOLD_DB` sits at −12 dB so 3:1 catches her occasional loud take and leaves the
   rest alone.

2. **Compression is not a level control.** What makes a track feel quiet at a correct integrated
   level is the target, not the dynamics. `--loudness` exposes that directly and defaults to
   `TARGET_LUFS`, so the knob cannot quietly redefine the master. YouTube normalises to about
   −14 LUFS, so a −16 master plays quieter than the material around it — worth knowing when
   judging a preview, not a reason to master hot.

3. **Two gains around the compressor, both measured.** Her source runs about −56 dB, so it has
   to reach working level before a threshold means anything; compressing then moves the loudness
   again, so a second static trim puts the program back on target.

**Also corrected: `taste_principles.md` §8 said duck music to −20 dB.** That figure was never
checked by ear and at −20 the bed is inaudible. The document now states 10 dB under the voice,
measured in 200 Hz – 4 kHz, per [S-022] and confirmed by Nathan on 2026-08-12. The code had been
right and the document wrong since the bed was first placed, which is the divergence CLAUDE.md
exists to prevent — logged rather than left.

---

### [S-024] — Silence was inferred from the transcript instead of measured from the audio
- **Date:** 2026-08-13
- **Video / shot:** MVI_0016, intro
- **Source:** human (Nathan: "there were just a couple too many mistakes still left in")
- **Status:** ACTIVE
- **Category:** audio / edit
- **What was wrong:** She fluffs the opening three times — "Hi—", "Hi—", then "Hi, I'm Katie."
  All three survived into the cut. `find_dead_air()` read every gap from the **word list**, so a
  1.7 s hole containing three full-level false starts was classified as dead air and trimmed
  *from the middle*, which preserved the loudest fluffs at both ends. `collapse_breath_runs()`
  had the same blindness at its floor: it walked the take backwards to collect its breath and
  stopped at the last *word*, stepping straight back over the fluffs and reinstating them.
- **Why it was wrong:** WhisperX emits words. Anything it fails to lexicalise — a false start, a
  stumble, a lip smack — leaves no trace in the transcript, and a function that only reads the
  transcript therefore classifies audible speech as silence. `config.SILENCE_THRESHOLD_DB` had
  sat in the file for two phases commented "for ffmpeg silencedetect" and wired to nothing,
  which is precisely the tell: the audio was always meant to be consulted and never was. This is
  the same defect as [S-020] and [S-021] — a measurement taken over a proxy the viewer does not
  receive. The viewer receives sound, not a transcript.
- **The rule going forward:** Silence is measured, never inferred. `voiced_spans()` runs
  `silencedetect` in the 80 Hz – 4 kHz band and every silence decision consults it. A voiced run
  **wholly inside** a word gap is a false start and is removed, named in the EDL. A voiced run
  that **touches either edge** of the gap belongs to the neighbouring word — WhisperX clips
  onsets routinely, and three real consonants in this clip alone start before the transcript says
  they do — so it is left alone. `audio_checked` records whether the measurement happened at all,
  because "not checked" and "checked and clean" must never share a value.
- **Auto-check:** Stage 2 refuses to cut a clip whose source audio it cannot read, and records
  `audio_checked` in the EDL stats; `test_a_false_start_is_removed_even_though_no_word_records_it`
  and `test_the_breath_does_not_walk_the_take_back_over_a_false_start` cover both sites.

---

### [S-025] — The music bed sat on top of her at 10 dB
- **Date:** 2026-08-13
- **Video / shot:** MVI_0016 preview
- **Source:** human (Nathan: "the music was just a little too loud")
- **Status:** ACTIVE
- **Category:** audio
- **What was wrong:** `MUSIC_UNDER_DB` was 10.0. Audible — which was the fix in [S-022] — but
  competing with the voice rather than sitting under it.
- **Why it was wrong:** The band correction in [S-022] was right and the number rode along with
  it unexamined. Once the level is measured somewhere meaningful, the value itself still has to
  be set by ear; a correct measurement of a wrong number is still a wrong number.
- **The rule going forward:** 13 dB under the voice in the 200 Hz – 4 kHz band. §8 and
  `music.py` both updated. The band stays where it is — that part was never in question.
- **Auto-check:** NONE — a bed level is a judgement by ear. `test_the_bed_level_matches_section_8`
  asserts only that `MUSIC_UNDER_DB` and §8 agree on whatever the current figure is.

---

### [S-026] — Every check read the input transcript, so every check inherited its mistakes
- **Date:** 2026-08-13
- **Video / shot:** MVI_0016, intro
- **Source:** human (Nathan: "I still hear 'I'm Katie I'm a foo Hi I'm Katie and I'm a food
  scientist.' How did you not catch that?")
- **Status:** ACTIVE
- **Category:** edit / process
- **What was wrong:** A whole failed take survived inside a single transcribed word. WhisperX
  gave the intro one token — `"I'm"` — spanning **2.0 seconds and four separate voiced bursts**,
  where the audio is "I'm Katie, I'm a foo—". The read-through added in [S-021] printed
  `Hi, I'm Katie, I'm a food scientist…`, a clean sentence, and passed. [S-024] could not see it
  either: that check only examines voiced audio *between* words, and this audio was nominally
  inside one.
- **Why it was wrong:** [S-021] made the pipeline read the cut, which was right, but it read the
  cut *through the input transcript*. A description of the output derived from the input inherits
  every one of the input's errors, in both directions — it missed a buried take, and it also
  reported two lines as unfinished that WhisperX had merely mistimed. Reading a proxy is what
  [S-020], [S-021] and [S-024] were each about; this is the same mistake one level further in.
  The transcript is not the cut. Only the cut is the cut.
- **The rule going forward:** Stage 2 **transcribes its own rendered output and reads that**, and
  the read-back is the authority — the input-transcript read-through is demoted to a provisional
  note. When the read-back hears a line twice, the earlier one is mapped back to source time
  through `TimelineMap.source_ranges()`, dropped, and the cut is re-read, up to
  `READBACK_MAX_PASSES`. A run that cannot complete the read-back fails as **unverified**, which
  is not the same as clean. Separately, a word running far below her speaking rate that contains
  more than one voiced run is a collapsed take, not a word, and its earlier bursts are cut.
- **Auto-check:** Stage 2 gates on the read-back and exits non-zero when it fails;
  `test_a_take_buried_inside_one_word_is_found`, `test_the_same_short_line_twice_is_caught` and
  `test_what_the_readback_heard_is_mapped_back_to_source_time` cover the three pieces.

---

### [S-027] — A check that is wrong twenty-eight times out of thirty is not strict, it is ignored
- **Date:** 2026-08-14
- **Video / shot:** Intro 001 — MVI_0018 / 0019 / 0020 / 0021, first assembly across clips
- **Source:** pipeline (the read-back on the 60-pick assembly)
- **Status:** ACTIVE
- **Category:** edit / process
- **What was wrong:** The first read-back of the assembled cut reported **30 problems, and 28 of
  them were not problems**. `group_sentences` ends a line at terminal punctuation *or* at a gap
  over a second, and `read_through` then asked of each line, on its own, whether it finished.
  On her unscripted delivery those two rules disagree constantly: she thinks mid-sentence, and
  every thinking pause became a line with no full stop on it — indistinguishable, line by line,
  from an abandoned take. "But if you're happy with your bread," was reported as trailing off.
- **Why it was wrong:** The check was built and tuned on MVI_0016, which is scripted VO, where a
  pause and a sentence end are the same event. It was then run on conversation, where they are
  not. A gate whose output is mostly false is worse than no gate: it cannot be read, so it gets
  skimmed, and the two real defects in that same report — a pick that ran into the head of the
  next take, and a stumble buried in a 3.4-second `"get"` token — were sitting in the middle of
  twenty-eight false ones. Both were genuine, and both were nearly missed for that reason.
- **The rule going forward:** `read_through` reads **sentences, not lines**. A line that starts
  lower-case after a line that has not finished is a breath, and `join_paused_lines()` puts the
  two back together before either check runs. A line starting with a capital is never merged —
  that is where a restart lives, and [S-021]'s defect stays visible. Where the merge cannot
  decide, the flag stands: on this cut one did, and it is reported as "could not tell" rather
  than silenced, per the standing rule that unknown and verified-good never share a
  representation.
- **Second defect, found in the same run.** `preflight()` globbed `*.mov` and `*.mp4` in lower
  case. All three Canon bodies write `.MOV`, so preflight reported "no footage in footage/" while
  standing on a gigabyte of it — and would have said the same thing to anyone who had just
  copied a card. Suffixes are compared case-folded.
- **Auto-check:** `test_a_thinking_pause_is_not_a_trailed_off_line` and
  `test_a_restart_after_a_pause_is_still_a_restart` — the second one fails if the merge is ever
  loosened enough to swallow [S-021].

---

### [S-028] — The read-back invents a repeat at a hard cut, and only at a hard cut
- **Date:** 2026-08-14
- **Video / shot:** Intro 001 — the join from MVI_0016 into MVI_0019 at 0:13
- **Source:** pipeline (the read-back on the assembled cut)
- **Status:** ACTIVE
- **Category:** edit / process
- **What was wrong:** The read-back reported the cut saying "As humans, we started using yeast
  thousands of years ago" and then, immediately, "As humans" again. Trimming the out-point by
  200 ms did not remove it. The phrase is **not in the audio**: silence measured off the tape
  puts a clear 730 ms gap either side of that join, the pick ends 110 ms into it, and
  transcribing each of the two shots on its own returns both clean. The repeat appears only when
  the two are transcribed as one file.
- **Why it was wrong:** Not an edit defect but a property of the instrument. Whisper decodes with
  the text it has already emitted in context, and at a splice — where room tone, level and room
  change between one sample and the next — it re-emits the opening of the phrase it just
  finished. The read-back was adopted in [S-026] precisely because it is the one check that
  does not inherit the input transcript's errors. It has its own, and this is it. A check
  trusted this much has to have its failure mode written down, or the next person burns an hour
  trimming a frame boundary that was never wrong — which is what happened here.
- **The rule going forward:** A repeat reported **at a join** is unconfirmed until the two shots
  either side have been transcribed separately, or the gap has been measured off the source
  audio. A repeat reported *within* a single shot still stands on its own: there is no splice
  there to hallucinate across. This does not weaken [S-026] — the read-back still outranks the
  input transcript everywhere. It means the read-back is evidence, not a verdict, exactly at the
  frames where two clips meet.
- **Auto-check:** none that is honest. The distinguishing evidence is a second transcription of
  the isolated shots, which costs another model pass per flagged join and is only worth spending
  when a join is flagged. Reported and reasoned about by hand.

### [S-029] — A word's timing is not a cut point: WhisperX folds a false start into the token beside it
- **Date:** 2026-08-23
- **Video / shot:** Yeast 001 — six joins: MVI_0045 @ 1:02 ("It's" timed 1.0 s), MVI_0040 @ 6:04
  ("yeast" timed 9.6 s), MVI_0041 @ 0:30 ("If" 0.46 s), @ 2:21 ("happens." 2.2 s), MVI_0038 @
  6:54 ("we" 0.38 s), @ 9:07 ("And" 2.6 s)
- **Source:** pipeline (the read-back on the assembled cut, twice)
- **Status:** ACTIVE
- **Category:** edit / process
- **What was wrong:** The picks file set every in- and out-point on a word boundary from the
  Stage 1 transcript. The transcript read clean — *"It's a little bit smaller"*, *"The yeast will
  continue to grow"* — and the cut said *"It's a little bit more… It's a little bit smaller"* and
  *"It grows, does this, this, the… The yeast will continue"*. The stumble was not a missing word
  in the transcript; it was inside the timing of a word that was there. WhisperX's aligner,
  given text with no token for the false start, stretches the neighbouring token over it: a
  one-syllable word timed at a second or more is a stumble wearing that word's name.
- **Why it was wrong:** [S-026] already says the input transcript's errors are invisible from
  the transcript, and [S-024] already says silence is measured, not inferred. This is the
  same lesson one level down: the *text* of a transcript can be right while its *timing* is a
  fiction, and a cut point taken from that timing inherits the fiction. The read-back caught all
  six, which is the argument for the read-back — but each one cost a model pass to find, and
  the tell was sitting in the words file the whole time.
- **The rule going forward:** A pick boundary on a word whose timed length is out of proportion
  to its letters — more than ~0.45 s for a word under five letters, or more than ~0.12 s per
  character — is not trusted. The point is measured off the audio with `silencedetect` and
  set exactly (`exact_start` / `exact_end` in a picks builder), and the read-back confirms it.
  The read-back still outranks both; this rule only says where to look *before* spending it.
- **Auto-check:** `cuts/yeast001/make_picks.py` prints a lead for every boundary word that
  fails the proportion test. A lead, not a verdict: on this cut the test also flagged four
  tokens that had merely absorbed a breath, and the read-back cleared them. Worth moving into
  `tools/assemble.py` once a second video uses it.
