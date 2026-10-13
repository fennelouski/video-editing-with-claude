# CLAUDE.md

Project context. Read this before touching anything. First time on this machine? See SETUP.md. File locations are in paths.json (resolved by scripts/config.py).

---

## What this is

An autonomous edit pipeline for a food-science YouTube channel. The host is a food scientist
explaining chemistry that home cooks miss. Her first video is on yeast.

The look is **cut cardboard, marker on paper, sage and oat, warm light, real shadows.** The
craft underneath is broadcast-grade: clean audio, tight pacing, deliberate grade, motivated cuts.

Those two things are not in tension — that is the entire thesis. Most handmade content fails
because the *craft* is amateur, not because the materials are humble. Most AI content fails
because it is glossy, symmetrical, and frictionless.

> **The imperfection lives in the artwork. Never in the timing, the audio, or the legibility.**

A cardboard diagram sitting 1.8° off-square is correct. A graphic arriving four frames late is
not.

---

## Non-negotiables

Violating any of these is a bug, no matter how much better the code looks.

1. **Nothing is generated.** No AI b-roll, no generated imagery, no procedural textures, no
   synthesised paper grain. Every pixel of texture came from her scanner or her camera. Missing
   assets **block the render** and produce a build sheet. See `style_guide.md` [S-001].
2. **Nothing is flattened.** The pipeline hands Final Cut Pro an FCPXML and stops. Every graphic
   stays independently movable, retimeable, deletable. Anything burned in is a decision the
   editor can no longer change. See [S-006].
3. **Timebase is 24000/1001 (23.976p), 1080p.** All three Canon bodies record "24p" as 23.976.
   All timing arithmetic happens in **integer frames** and converts to seconds or rationals
   exactly once, at the edge. Never write a float frame rate into an ffmpeg or FCPXML argument.
   See [S-007].
4. **Never trim a silence below 120 ms.** Cutting pauses to zero is the loudest signature of a
   machine edit. See [S-002].
5. **Never `#000000` or `#FFFFFF`** in the graphic layer, and no hue outside the Sage & Oat
   palette in `config.PALETTE`. See [S-003].
6. **Graphics step on 2s.** A new position every 2nd frame. If anything in the graphic layer
   moves on an odd frame, the stop-motion illusion breaks. Footage and captions run at full rate.
7. **Chemistry is escalated, never automated.** Any scientific claim, number, temperature,
   mechanism, or structure goes to her. The pipeline does not get a vote. See
   `config.ESCALATE_TO_HUMAN`.

---

## The documents are the spec

| File | What it governs |
|---|---|
| `taste_principles.md` | The standing specification — palette, safe zones, type, motion, grade, audio, pacing, the §12 review rubric. Section numbers are referenced throughout the code. |
| `style_guide.md` | The correction log. Every `ACTIVE` entry is a binding constraint ranked **above** code defaults. Same mistake never twice. |
| `font_character_set.md` | What glyphs the marker font needs and how many versions of each. |
| `molecular_kit.md` | The physical asset system for the atoms→molecules→proteins→gluten→bread ladder. |
| `HANDOFF_claude_code.md` | Scoped work items with acceptance criteria. |
| `README.md` | Setup and operation. |

**When code and `taste_principles.md` disagree, the document is right and the code is a bug.**
If a rule genuinely needs to change, change the document first and log it in `style_guide.md` —
don't quietly diverge.

---

## Architecture

```
stages 1–5  ─────►  FINAL CUT PRO  ─────►  stage 6
 transcribe          human edit,           Watch agent scores
 cut, plan,          grade, export         the export, appends
 render graphics                           corrections
      ▲                                          │
      └──────────  style_guide.md  ◄─────────────┘
```

| File | Role |
|---|---|
| `scripts/config.py` | **Single source of truth.** Every constant from `taste_principles.md`. Never hard-code these in a stage. |
| `scripts/stepclock.py` | Stop-motion timing core. Seeded deterministic jitter, step quantisation, entrance/exit poses. |
| `scripts/fcpxml.py` | FCPXML 1.13 writer, `.itt` captions, `TimelineMap`, validation. |
| `scripts/stage1_transcribe.py` | WhisperX word-level timings. |
| `scripts/stage2_roughcut.py` | Dead air, retakes, fillers → EDL + rough-cut FCPXML. |
| `scripts/stage3_plan.py` | Annotated script (inline markers or Word comments) → timed graphic plan. |
| `scripts/stage4_assets.py` | Asset resolution → build sheet. Hard gate. |
| `scripts/stage5_composite.py` | Cutout compositing → ProRes 4444 alpha layers + FCPXML package. |
| `scripts/stage6_watch.py` | §12 rubric scoring → `style_guide.md` entries. |
| `scripts/run_pipeline.py` | Orchestration, preflight, stage gating. |

---

## Conventions

- **Source time vs timeline time.** Stage 3 anchors cues to the transcript (source time). Stage 2
  removes ~30% of that source. Anything positioned on the timeline — graphics, markers, chapters,
  captions — **must** be remapped with `fcpxml.TimelineMap`. This has caused two separate bugs
  already; assume it is the cause of any "graphic in the wrong place" report.
- **Discovery is allowlist plus evidence.** `script/` is the only place the annotated script
  lives. Anything that auto-discovers an input file must require positive evidence that the file
  is what it claims to be — never a denylist of things to skip, which silently degrades as the
  project grows. An explicitly passed path is trusted; a discovered one must prove itself.
  See [S-009]. Stage 3 works this way; Stage 4's asset resolution and Stage 6's `find_export()`
  have the same shape and have **not** been brought in line yet.
- **Check the output, not the input.** A description of a result derived from its inputs
  inherits every one of the inputs' errors. Stage 2 built a cut from a WhisperX transcript and
  then checked the cut by reading that same transcript, so a failed take collapsed into a single
  2.0 s `"I'm"` token was invisible — the script read clean while the audio said "I'm Katie, I'm
  a foo—" [S-026]. Stage 2 now transcribes its own render and reads *that*, and the read-back
  outranks the input. The same shape has now bitten five times ([S-020], [S-021], [S-024],
  [S-026], and the music level): a measurement taken over a proxy the viewer never receives.
  Reconstruct what the audience actually gets, and measure that.
- **"Unknown" and "verified good" are different facts, and must never share a representation.**
  This has now bitten three times, so it's a rule rather than an observation. `dtd_problems()`
  returns `None` when Final Cut isn't installed, not `[]` — an empty problem list is a green tick
  it didn't earn. `reviewed_by: "unreviewed"` satisfied a non-empty check while carrying none of
  its meaning [S-016]. An inferred backdrop reference stood in for a measured one and hid a
  defect for two phases [S-013]. Any value that records whether something was checked must be
  able to say "not checked" in a form that cannot be mistaken for "checked and fine".
- **Never drive GUI automation from a session that holds focus.** Synthesised clicks and
  keystrokes land in whatever is frontmost, which during a shell command is the terminal running
  it — input intended for Final Cut arrives in the agent session generating it. Prefer reading
  an application's own state: Final Cut's library is a SQLite database, so what it actually
  parsed and conformed can be read rather than inferred from pixels. Where state can't be read,
  hand the check to a human rather than automating it blind.
- **Determinism.** Seeded PRNG only. No `Math.random()`, no `random` without the seed, no
  `Date.now()`, no network calls during a render. The same input must produce byte-identical
  frames.
- **Comments explain why, not what.** The codebase's existing comments cite the principle a
  constraint comes from. Match that.
- **Failures are loud and actionable.** A stage that can't proceed says what's missing and what
  to do about it. Never silently substitute a default.
- **Don't delegate terminal work to a human.** If a command can be run from the agent session,
  run it. Ask Nathan only for things that physically require him: clicking in a GUI, shooting
  footage, or looking at rendered pixels. Handing him a command line to paste and a traceback to
  relay is a failure of the tool, not a step in the workflow.
- **Every human-facing entry point takes what a human will actually hand it.** Finder produces
  `.fcpxmld` bundles, paths with spaces and colons, aliases, and trailing slashes. macOS ships a
  system Python that is not the project venv. An entry point that accepts only the canonical form
  and dies on a stack trace otherwise is unfinished. Resolve what can be resolved, and explain
  what can't — in one sentence, naming the fix.

---

## Verification expectations

There is currently **no committed test suite** — the pipeline was verified manually against
throwaway fixtures. Building that suite is early work.

Anything added should be verifiable without a human watching a video:

- Timing changes → assert frame-grid alignment and step quantisation.
- FCPXML changes → `fcpxml.validate()` plus a structural round-trip parse.
- Compositing changes → assert alpha preserved, bounding boxes inside the safe box, no pure
  values, non-zero frame-to-frame delta during holds.
- Anything touching `style_guide.md` → assert entries are grouped by defect, not per-frame.

---

## Things not to do

- Don't add a web UI. Two people use this, both comfortable in a terminal.
- Don't add a "smart" auto-styling system. The point of `taste_principles.md` is that the
  decisions are already made; re-deciding them per video is the failure mode this project exists
  to prevent.
- Don't reach for a dependency to avoid twenty lines of stdlib. The `.docx` comment parser reads
  the package XML directly for exactly this reason.
- Don't "clean up" the imperfection budget, the idle jitter, or the breath floor. They look like
  bugs and are the product.
