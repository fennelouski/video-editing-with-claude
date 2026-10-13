# Handmade video pipeline

An autonomous edit pipeline for a food-science channel with a cut-cardboard, marker-on-paper
look — and full YouTube production polish underneath.

The governing documents are:

- **`taste_principles.md`** — the standing specification. Palette, safe zones, type scale,
  stop-motion timing, grading, audio, pacing, and the anti-AI checklist. Read this first.
- **`style_guide.md`** — the correction log. Every time a render gets sent back, it's logged
  here, and the pipeline reads it before generating anything. Same mistake, never twice.

The native macOS app is in **`Clauto Editor/`**. See its [requirements and verification checklist](Clauto%20Editor/docs/IMPLEMENTATION.md)
for the current implementation, remaining milestones and local build entrypoint.

## Two rules that shape everything

**1. The pipeline never generates footage or imagery.**

There is no AI b-roll stage, and there won't be. Generated footage is the one thing that can't
be rescued by grading or texture — it's recognisable, and one shot of it discredits the other
nineteen minutes. When an asset is missing, Stage 4 stops the run and writes a **build sheet**:
a list of what to cut, draw, or shoot. See `style_guide.md` [S-001].

**2. The pipeline never flattens a master.**

Finishing happens in Final Cut Pro. Stage 5 hands FCP an **FCPXML** — the cut timeline, her
graphic layers attached as connected clips at the right timecodes, cue markers, chapter markers,
and roles. Every graphic stays independently movable, retimeable, and deletable. Anything the
pipeline burns in is a decision she can't revise, so it burns in nothing. See [S-006].

```
stages 1–5  ─────►  FINAL CUT PRO  ─────►  stage 6
 transcribe          she cuts, grades,      Watch agent reviews
 cut, plan,          places b-roll,         the export and logs
 render graphics     exports                corrections
      ▲                                          │
      └──────────  style_guide.md  ◄─────────────┘
```

**Timebase: 23.976p (24000/1001), 1080p.** All three bodies — T3i, R100, RP — record "24p" as
23.976; none offers true 24.000. The T3i is 1080-only, which sets the timeline resolution; R100
and RP 4K is still worth shooting for reframing latitude. See `taste_principles.md` §2 and
[S-007], [S-008].

---

## Setup

Prerequisites — run these in your own Terminal:

```bash
# macOS
brew install ffmpeg git python@3.11
```

Then, from this folder:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

Verify:

```bash
./run run_pipeline.py --dry-run
```

Preflight will tell you exactly what's still missing.

---

## Layout

```
assets/
  cutouts/      matted PNGs of the cardboard pieces — 4–6 variants each
  textures/     scanned surfaces; paper-grain.png is REQUIRED (§4.3)
  fonts/        her marker font (woff2) + Work Sans
  foley/        cardboard taps, paper slides, marker squeaks
  music/        acoustic beds only
  luts/         the channel LUT
footage/
  a-cam/  b-cam/  broll/  macro/  audio/
script/         the annotated script (.docx or .md)
templates/      HTML/CSS layouts for graphics built on her textures
scripts/        the six stages
build/          everything the pipeline produces (safe to delete)
```

---

## Running it

### One way to run things

Always `./run`. It execs `.venv/bin/python`, so there is one correct invocation and it cannot
be got wrong — `python` is often not on `PATH`, and `python3` on macOS is Xcode's 3.9 rather
than this project's venv. Both failures look like bugs in the pipeline rather than in the
invocation. Scripts resolve by bare name from `scripts/` and `scripts/tools/`.

Every entry point also takes what Finder actually produces: `.fcpxmld` export bundles, paths
with spaces and colons, trailing slashes, `~`, symlinks and aliases. Anything it can't resolve
comes back as one sentence naming the fix.


```bash
./run run_pipeline.py --to 5 --project yeast    # everything up to the FCP handoff
./run run_pipeline.py --only 6 --project yeast  # review what she exported from FCP
./run run_pipeline.py --aspect 9:16             # the vertical cut
./run run_pipeline.py --from 3                  # resume
./run run_pipeline.py --preview                 # also render a flat preview mp4
```

### Preparing artwork

```bash
# one photo of several pieces on grey seamless -> matted PNGs in assets/cutouts/
./run tools/segment_sheet.py sheets/session01_a.jpg \
    --keys yeast_cell-budding,thermometer,flour_sack --variant a

# reuse one session's grey-card balance across every later sheet
./run tools/segment_sheet.py sheets/session01_b.jpg \
    --keys yeast_cell-budding,thermometer,flour_sack --variant b \
    --gains 0.9444,1.0000,1.1121
```

`--keys` are matched to pieces in reading order — top to bottom, then left to right. Anything
unnamed is written as `unnamed-NN` and reported, never guessed at. A piece under the §1.2
2400 px floor is skipped with a reshoot instruction and the tool exits non-zero, because a
cutout the edit can't push in on is not usable and Stage 4 is too late to find out.

Shoot each piece 4–6 times per §1.2 and pass `--variant a` … `f`; those become the stop-motion
jitter cycle.

`--seamless` and `--shadow` are both required — [S-013], [S-014]. Read them off the session's
grey-card frame, or record them in a `<sheet>.capture.json` sidecar:

```json
{"seamless": [0.49, 0.46, 0.41], "deepest_shadow": [0.34, 0.32, 0.29]}
```

Neither is inferred from the sheet being matted. The [S-012] edge-extend direction check
measures colour against the seamless and would otherwise be judging the pixels by themselves,
and a guessed shadow floor would bake a lighting-dependent constant into code.

### Building the marker font

```bash
# one sheet per character, or a manifest mapping sheets to characters
./run tools/build_font.py sheets/e_v01-20.png --glyph e --min-gap 90
./run tools/build_font.py sheets/*.png --manifest sheets/glyphs.json --min-gap 90

# then confirm calt survives into a real browser, not just the feature file
./run tools/verify_font_browser.py assets/fonts/HerMarker.woff2 --char e
```

`--min-gap` must exceed the largest gap *inside* a glyph and stay under the cell pitch; it has
no default for that reason. `--tolerance` is the simplification tolerance in font units and
defaults low on purpose — the wobble, the bleed and the marker skips are the value.

`--baseline` and `--min-gap` both want setting from her test sheet before any production
sheets are lettered.

### Tests

```bash
./run -m pytest           # the whole suite
./run -m pytest tests/test_stepclock.py -q
```

Runs against synthetic fixtures built in `tests/fixtures.py` — no footage, fonts, or asset
library required, so it works on a fresh clone. `ffmpeg` is the only external dependency.

Those fixtures generate stand-in cutouts and paper grain, which [S-001] forbids *on screen*.
That rule governs what reaches the video, not what a test hands a function; nothing under
`tests/` is ever written into `assets/`.

### The six stages

| # | Stage | What it does |
|---|---|---|
| 1 | `stage1_transcribe` | WhisperX word-level timings. Everything downstream keys off this. |
| 2 | `stage2_roughcut` | Removes dead air, repeated takes, isolated fillers — **never trimming a gap below 120 ms**, because cutting pauses to zero is the loudest machine-edit tell. Emits an FCPXML with a marker at every join explaining what was cut. |
| 3 | `stage3_plan` | Parses her annotated script (inline markers or Word comments) into a timed graphic plan, anchored to the transcript. Hold times come from the §5.4 formula, never guessed. |
| 4 | `stage4_assets` | Resolves every asset. Missing ones produce a build sheet and **stop the run**. |
| 5 | `stage5_composite` | Animates her scanned cutouts on the stop-motion step clock, applies the real grain pass and contact shadows, renders each graphic as its own ProRes 4444 alpha layer, and builds the FCPXML package plus an `.itt` caption sidecar. |
| 6 | `stage6_watch` | Runs **after** Final Cut. Samples frames from her export and scores them against the §12 rubric. Fails get written back into `style_guide.md` as corrections the next run will read. |

### The Final Cut handoff

Stage 5 writes two files into `build/exports/`:

- **`<project>.fcpxml`** — File ▸ Import ▸ XML… in Final Cut. Targets **FCPXML 1.13 (FCP 11)**.
  If FCP refuses the import, the version is the first thing to check: `FCPXML_VERSION` in
  `config.py`.
- **`<project>.captions.itt`** — import as captions. Native FCP caption objects, editable as
  text. The pipeline decides the line breaks (2 lines, ≤36 chars, balanced) so they break on
  sense rather than on width.

Both are remapped onto the **cut** timeline, not source time — including the captions, which
drop the words that were edited out. When she exports, drop it in `build/exports/` and run
stage 6.

**What arrives in the timeline:** the cut on the primary storyline with `Dialogue` audio roles;
graphics on lane 1 with the `Graphics.Cutouts` role, so the whole layer solos or hides in one
click; a to-do marker at every b-roll, macro, camera, and VO cue she still has to place;
chapter markers at each chapter card.

---

## Annotating the script

Either inline in a `.md`:

```
So the yeast starts eating the sugar [[GFX: key_term | text="Fermentation" | asset=cutout:yeast_cell-budding]]
and that's where the CO₂ comes from. [[MACRO: bubbles rising in the starter]]
```

…or as Word comments using the same syntax. Cue kinds: `GFX`, `BROLL`, `MACRO`, `VO`, `CAM`,
`CHAPTER`, `NOTE`. Templates: `chapter_card`, `key_term`, `lower_third`, `diagram`, `gauge`,
`comparison`, `stat`, `quote`.

Each cue anchors to the phrase it follows, so the graphic lands as she finishes saying it.
Anything that can't be anchored is reported, never silently placed.

**The script goes in `script/`.** That's the only location Stage 3 discovers. If it's left in the
project root, Stage 3 will spot it, name it, and stop — it won't guess, because the root is full
of documents and picking the wrong one would mean planning an entire video off `CLAUDE.md`. A
path passed explicitly on the command line always wins.

---

## First-run checklist

1. `assets/textures/paper-grain.png` — flat-scan a blank sheet. Stage 5 refuses to run without
   it; §4.3 forbids substituting generated noise.
2. `assets/fonts/` — her marker font. Make sure `calt` is on and there are 3–5 alternates per
   common glyph, or repeated letters will give it away (§3.2).
3. One surface texture (`kraft`, `butcher`, `notebook`) at ≥4000 px.
4. A clip in `footage/a-cam/`.
5. An annotated script in `script/`.
6. Cutouts in `assets/cutouts/`, 4–6 variants each, named `<key>_v01_a.png`, `_b`, `_c`…

Then: `./run run_pipeline.py`

---

## Three things worth knowing

**Stage 5 is cheap by design.** Because graphics step on 2s, it renders one composite per step
and duplicates it across held frames — roughly half the work of rendering every frame, and it's
also what makes the motion correct.

**Everything is remapped from source time to timeline time.** Stage 3 anchors cues to the
transcript, which is source time. Stage 2 then removes ~30% of that source. A graphic anchored
at source 31.5s belongs at timeline ~19s. `fcpxml.TimelineMap` handles this for graphics,
markers, chapters, and captions alike; a cue anchored to footage that got cut snaps to the
nearest surviving frame and says so.

**Stage 6's job is to be annoying.** It will flag things that are fine. Read the report, dismiss
what's wrong, and — importantly — write the "rule going forward" line on every entry it appends
to `style_guide.md`. An entry without a testable rule teaches the pipeline nothing.

## Clauto Editor (macOS app)

A native app that wraps this pipeline in a GUI: setup, projects, drag and drop, iteration. Design docs: [`Clauto Editor/docs/`](Clauto%20Editor/docs/README.md).
