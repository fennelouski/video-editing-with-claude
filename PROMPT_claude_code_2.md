# Prompt for Claude Code — round two

Copy everything below the line into Claude Code, run from `~/Documents/Videos`.

---

Transparency is confirmed. Nathan checked the smoke timeline in Final Cut: the cutouts composite
with transparent surrounds, no black boxes. ProRes 4444 alpha survives the handoff.

That closes the last render-time unknown. The FCPXML contract is now verified end to end except
for two things the XML round-trip will close as a by-product of Phase 6.

Re-read `CLAUDE.md` and the recent `style_guide.md` entries before starting — several were added
since your last session, including [S-016], [S-017], and two new conventions in `CLAUDE.md`
(the "unknown vs verified good" rule, and never driving GUI automation from a focused session).

Work the phases in order. **Stop and report at the end of each.** Ask before any architectural
decision not already settled in the documents.

## Phase 6 — FCPXML round-trip reader

`HANDOFF_claude_code.md` item 3. This closes the learning loop, which nothing else does, and it
closes the two open smoke-test checks on the way.

Build the reader first, then use it to answer both open questions:

1. **What 9:16's undefined format resolved to.** File ▸ Export XML on the vertical smoke project.
   FCP writes the format it actually built, with explicit `width`, `height` and `frameDuration`.
   Assert it is 1080×1920 at 1001/24000. If it isn't, that's a real defect in
   `ASPECTS["9:16"]["fcp_format_name"]` and it needs fixing before any vertical cut is made.
2. **The `.itt` caption import.** Import the captions, export XML, and confirm they come back as
   caption elements with the timings Stage 5 wrote. Appearance is styled in FCP under [S-005],
   so that isn't ours to check — but "did they land, and are they in sync" is.

Then the reader proper: diff an FCP-exported FCPXML against what the pipeline generated, and
write the differences into `style_guide.md` as correction entries.

- **Cuts restored** — Stage 2 removed something it shouldn't have. Highest-priority signal.
- **Graphics deleted** — the pipeline proposed something unwanted.
- **Graphics retimed** — report the delta, so the §5.4 hold constant can be tuned rather than
  guessed.
- **Graphics moved** — Stage 3's anchoring is landing early or late; report the direction.

Reuse `fcpxml.TimelineMap` for the source↔timeline mapping. Note that entries this writes are
subject to [S-016]: an auto-generated entry with an unfilled rule line must gate the pipeline,
and this reader will be the main producer of them.

## Phase 7 — Foley placement

`HANDOFF_claude_code.md` item 7. §8 calls foley the secret weapon: half an hour of recorded
table sounds buys more credibility than anything in the visual spec.

Plan + foley library → an FCPXML audio lane with a hit at each graphic's place-down frame, on
the `Effects.Foley` role, varied so the same tap never fires twice consecutively.

Two things to get right: the hit lands on the **place-down** frame, not the entrance start —
the sound is the piece touching the table. And the variation selector must be seeded and
deterministic like everything else in `stepclock`.

The library doesn't exist yet. Build against synthesised clicks; Nathan can record the real
thing in an afternoon and it drops in.

## Phase 8 — Real footage, end to end

**Needs a clip from Nathan first — ask for it when you reach this phase.** Two minutes of him
talking, shot at 24p so the timebase matches (most phones offer it; 30p would make the FCPXML
timing wrong and limit the test to stages 1–2).

Everything so far has run on fixtures I wrote to match the same assumptions the code makes.
This is the first test of:

- WhisperX on real speech — accuracy, word timings, how it handles her cadence.
- Silence detection against real room tone rather than digital silence. The 120 ms breath floor
  has never met an actual pause.
- Retake detection against real stumbles rather than synthesised near-duplicates.

Expect this to find things. Report rather than fix on the first pass.

## Phase 9 — Camera matching and face detection

Items 5 and 6. Camera matching needs colour-checker frames from the T3i, R100 and RP — ask
Nathan, it's a ten-minute shoot. Face detection needs nothing and must degrade gracefully when
MediaPipe is absent.

## Blocked on her, not on you

Deskew and registration-mark detection stay unbuilt until the two test artifacts exist:

1. **Glyph sheet** — registration marks, the intended cell grid, ~20 versions of `e` or `a`.
2. **Cutout test capture** — three or four pieces close enough to cast shadows into the gaps,
   including one dark near-neutral piece, which is the only real-data check on [S-014].

Don't build either blind. If she delivers them mid-phase, finish what you're on and report.

## Housekeeping

`HANDOFF_claude_code.md` still reads as if nothing is done. Mark items 1, 2 and 4 complete with
a line on what shipped, so the document doesn't drift from reality — same rule as
`taste_principles.md`.

## Standing instructions

- Commit at the end of each phase with a message explaining the *why*.
- When you find a bug in the existing code, fix it, and add a test that would have caught it.
- If a fix changes a rule in `taste_principles.md`, update the document and add a
  `style_guide.md` entry. Don't let code and spec silently diverge.
- Tell me when something in the spec is wrong or unachievable rather than working around it.
- Prefer reading an application's own state — a schema, a database, an export — over inferring
  it. That instinct has found the two most serious defects in this project so far.
