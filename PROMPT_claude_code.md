# Prompt for Claude Code

Copy everything below the line into Claude Code, run from `~/Documents/Videos`.

---

You're picking up an in-progress project: an autonomous video editing pipeline for a food-science
YouTube channel with a handmade, cut-cardboard aesthetic that hands off to Final Cut Pro.

**Start by reading `CLAUDE.md`.** Then read `taste_principles.md`, `style_guide.md`, and
`HANDOFF_claude_code.md`. The documents are the specification — where code and documents
disagree, the document is right and the code is a bug. The seven non-negotiables in `CLAUDE.md`
are not stylistic preferences; violating any of them defeats the purpose of the project.

The six pipeline stages exist and work. They were verified manually against throwaway fixtures
that no longer exist, and there is **no committed test suite**. That's the first gap to close.

Work through the phases below in order. **Stop at the end of each phase and report** — don't run
straight through. Ask me before making any architectural decision that isn't already settled in
the documents.

## Phase 0 — Environment and baseline

1. Verify prerequisites: `ffmpeg`, `python3` ≥3.10, `git`. Install anything missing via Homebrew.
2. Create `.venv`, install `requirements.txt`. WhisperX pulls torch and is large — expect this to
   take a while, and confirm it imports afterward.
3. Run `python scripts/run_pipeline.py --dry-run` and report exactly what preflight flags.
4. Add a `.gitignore` (`.venv/`, `build/`, `__pycache__/`, `*.pyc`, `.DS_Store`, and the large
   binary asset directories), then `git init` and make an initial commit.

Report what's installed, what's missing, and anything preflight surfaced that looks wrong.

## Phase 1 — Test suite and fixtures

There's no way to safely change anything until this exists.

1. Build `tests/fixtures.py` that synthesises: a word-level transcript with a deliberate repeated
   take, filler words, and long gaps; an annotated markdown script exercising every cue kind
   (`GFX`, `BROLL`, `MACRO`, `VO`, `CAM`, `CHAPTER`, `NOTE`); stand-in cutout PNGs with alpha and
   irregular edges, 5 variants each; a paper-grain texture; and short synthetic video at
   23.976fps via ffmpeg.
2. Write pytest coverage for the invariants in `CLAUDE.md` § Verification expectations. At
   minimum:
   - `stepclock`: jitter is deterministic and reproducible; differs per element; stays inside the
     §2.3 budget; **values change only on even frames**; resting-pose rotation alternates sign
     between neighbours and never lands on exactly 0°.
   - `config.fcp_time` / `fcp_duration`: every output is an exact multiple of `1001/24000`.
   - `stage2`: no gap in the output EDL is below `BREATH_FLOOR_MS`; the *later* of two repeated
     takes survives, not the earlier.
   - `stage3`: markdown headings don't pollute anchor text; `MACRO`/`BROLL` bodies are parsed as
     free text, not template names.
   - `fcpxml`: generated documents pass `validate()`; connected-clip offsets reconstruct to the
     correct absolute timeline position; nothing extends past the sequence duration; `.itt` lines
     never exceed `CAPTION_MAX_CHARS_PER_LINE` and cards never exceed `CAPTION_MAX_LINES`.
   - `TimelineMap`: source→timeline mapping is correct across cuts, and a cue anchored inside a
     removed span snaps to the nearest surviving frame.
   - `stage5`: alpha survives compositing; bounding boxes land inside the safe box; no pure black
     or white; frame-to-frame delta is non-zero throughout the hold phase.
3. Make it run green, then commit.

**Do not change pipeline behaviour in this phase.** If a test fails, report it and ask — a
failure might be a real bug or might be a test encoding the wrong expectation.

## Phase 2 — Scan sheet segmenter

`HANDOFF_claude_code.md` item 2. She is producing sheets right now, so this unblocks her.

Build `scripts/tools/segment_sheet.py`: one photo of several pieces on mid-grey seamless →
individual matted PNGs named to the `assets/cutouts/<key>_v01_<a-f>.png` convention.

Honour `taste_principles.md` §1.3 exactly: **1–2px feather** (a 0px matte gives the vector-crisp
edge we're specifically avoiding), preserve torn-edge fibre, grey-card-driven white balance, and
reject pieces under 2400px on the long edge with a clear message.

## Phase 3 — Font builder

`HANDOFF_claude_code.md` item 1, and read `font_character_set.md` first. She's lettering ~1,320
glyphs, roughly 20 versions of each high-frequency character.

Grid segmentation → SVG trace → UFO assembly → `calt` generation → woff2.

Two things determine whether this works:

- **Don't smooth the traces.** The wobble, the bleed, and the marker skips are the value. Make
  the simplification tolerance a tunable and default it low.
- **Cycle alternates in order, not randomly.** Random selection repeats by chance, which is the
  exact artifact the alternates exist to prevent.

Acceptance test, automated: render a string with every letter tripled (`aaa bbb ccc…`) and assert
no two adjacent glyphs share an outline hash. Verify in a real browser render, not just by
inspecting the feature file — FontForge and fontmake disagree about `calt` ordering.

## Phase 4 — FCPXML round-trip reader

`HANDOFF_claude_code.md` item 3. Closes the learning loop, which nothing else does.

Parse an FCPXML exported back out of Final Cut, diff it against what the pipeline generated, and
write the differences into `style_guide.md` as correction entries: graphics deleted, retimed
(report the delta so the §5.4 hold constant can be tuned rather than guessed), moved, and — the
highest-priority signal — cuts that were restored, meaning Stage 2 removed something it
shouldn't have.

Reuse `scripts/fcpxml.py`; `TimelineMap` already handles the source↔timeline mapping.

## After that

Items 4–7 in `HANDOFF_claude_code.md` (molecule layout solver, camera-matching helper, Stage 6
face detection, foley auto-placement), in whatever order makes sense once the above is solid.

## Standing instructions

- Commit at the end of each phase with a message explaining the *why*.
- When you find a bug in the existing code, fix it, and add a test that would have caught it.
- If a fix changes a rule in `taste_principles.md`, update the document and add a
  `style_guide.md` entry. Don't let code and spec silently diverge.
- Match the existing comment style: explain why a constraint exists and cite the principle
  section it comes from.
- Tell me when something in the spec is wrong or unachievable rather than working around it
  quietly.
