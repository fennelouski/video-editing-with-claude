# taste_principles.md

**Design constraints for the channel. This is a hard specification, not inspiration.**

Every graphic, title, caption, transition, and grade produced by this pipeline must satisfy
every rule below. When a rule and a creative impulse conflict, the rule wins.

---

## 0. The thesis

> **Handmade in every surface. Professional in every decision.**

The look is cut cardboard, marker on paper, sage and oat, warm light, real shadows.
The craft underneath is broadcast-grade: clean audio, tight pacing, deliberate grade,
motivated cuts, a real hook, a real outro.

Those two things are not in tension — they are the whole point. Most handmade content
fails because the *craft* is amateur, not because the *materials* are humble. And most
AI content fails because it is glossy, symmetrical, and frictionless.

**So: the imperfection lives in the artwork. Never in the timing, the audio, or the legibility.**
A cardboard cell diagram that sits 1.8° off-square is correct. A graphic that arrives
four frames late is not.

### 0.1 The three laws

1. **Every texture on screen is real.** Scanned, photographed, or drawn by her hand.
   No procedural noise, no CSS gradient, no generated "paper" texture. Ever.
2. **Nothing is flat and nothing is perfect.** Every element has a shadow, an edge, a grain,
   and a small deliberate rotation. Perfect centering and vector-crisp edges are the loudest
   AI tells that exist.
3. **Subtract before you add.** One idea per composition. Handmade + busy = craft-fair chaos.
   Handmade + spare = expensive.

---

## 1. The physical asset system

This is the foundation. The pipeline animates *her real artwork* — it never draws its own.

### 1.1 What gets built physically

| Asset class | Examples for the yeast video |
|---|---|
| **Cutouts** | Yeast cell (budding + parent), flour sack, sugar molecule, CO₂ bubble, loaf, thermometer, clock face, jar |
| **Cards** | Chapter title cards, term-definition cards, "common mistake" cards |
| **Labels** | Hand-lettered arrows, brackets, circles, underlines, checkmarks, ✗ marks |
| **Surfaces** | Kraft paper, butcher paper, linen, cutting board, floured counter, notebook page |
| **Marks** | Marker strokes, arrows, scribbled emphasis, crossed-out words, coffee rings |

Build a **library**, not one-offs. Every arrow, bracket, and underline she cuts or draws once
gets reused across every video. That consistency is what makes it read as a *channel* rather
than a craft project.

### 1.2 Capture specification

Consistency of capture matters more than the quality of any single piece. Lock this down once.

- **Rig:** overhead copy-stand or tripod with the camera arm out, sensor plane parallel to the
  table. Shoot from directly above. A phone works if it's locked down.
- **Light:** two soft sources at 45° from opposite sides, or one large diffuse window with a
  white bounce opposite. Goal is *near-shadowless on the art* — the contact shadow gets added
  in comp so it can be animated. A cross-polarizing filter kills marker specular if it shows.
- **Exposure:** shoot RAW. Include a **grey card and color checker in the first frame of every
  session.** White-balance every session to it. This single habit is what keeps kraft paper the
  same kraft across three months of shooting.
- **Resolution:** every piece fills ≥ **2400 px on its long edge** so the edit can push in on it.
- **Backing:** shoot on a **neutral mid-grey seamless**, with the piece raised ~10 mm on foam
  tape. Grey mattes cleanly and doesn't spill color into the paper fibers the way green does.
  **Measure and record the seamless value every session** — every matting decision is made
  relative to it, and inferring it per-sheet lets it drift with exposure and white balance.
  The grey card frame above already establishes it. See [S-012], [S-013].
- **Variants:** shoot every piece **4–6 times**, nudging it a millimeter or two between frames.
  These become the stop-motion jitter cycle in §5 — free, and genuinely real.
- **Never shoot a piece perfectly square to frame.** 1–3° off, always.

### 1.3 Extraction and file specs

- Matte to **PNG with alpha**, 16-bit where possible. Feather the matte **1–2 px** — a 0 px
  matte gives a vector-crisp edge, which is the tell we're trying to avoid.
- **Preserve fiber.** Cut and torn edges must keep their irregularity. If the matte eats the
  fuzz, redo the matte. Never trace a cutout into a clean path.
- Store the *unmodified* extraction — meaning the **interior**. The matte boundary does not
  coincide with the optical edge (a lens renders a cut edge over several pixels), so a thin
  ring of edge colour is rewritten by `edge_extend`, always bleeding cardboard outward and
  never seamless inward. Geometry is never resampled. See [S-012].
- **Naming:** `assets/cutouts/<subject>_<descriptor>_v<NN>_<variant>.png`
  → `assets/cutouts/yeast_cell-budding_v01_a.png`
- **Texture library:** `assets/textures/` — surfaces at ≥ 4000 px, tileable-adjacent, one file
  per material per lighting condition. Minimum set: kraft, butcher paper, notebook, linen,
  cutting board, floured surface, paper grain (flat-scanned, for overlay).

---

## 2. Canvas and safe zones

| Target | Resolution | Frame rate |
|---|---|---|
| **16:9 primary (YouTube)** | 1920 × 1080 | **23.976p** (24000/1001) |
| **9:16 clips (Shorts/Reels)** | 1080 × 1920 | 23.976p |

**23.976, not 24.000.** All three bodies in rotation — Canon T3i, R100, RP — record what they
label "24p" as 23.976; Canon consumer bodies have no exact-24 mode in NTSC regions. The whole
chain runs on 24000/1001, and a true-24 asset dropped into this timeline drifts audio
progressively. It carries the slight strobe that reads as *film* rather than *video*, and it
halves cleanly into the ~12 fps stop-motion step in §5.

**The timeline is 1080p, and that is set by the T3i** — it has no 4K mode. R100 and RP 4K is
still worth shooting: it gives real reframing and punch-in latitude inside a 1080 timeline.
Note the T3i is a 2011 8-bit body whose colour science is visibly greener and flatter than the
R-series; it needs a per-body correction *before* the channel LUT, not after. Its 12-minute
clip limit also means long takes arrive in segments.

### 2.1 Margins — nothing crosses these

**16:9 (1920 × 1080):** left/right **120 px**, top **80 px**, bottom **100 px**
(→ **160 px** when captions are on screen).
Player-chrome exclusion: bottom **120 px**, right **320 px** (progress bar, timestamp, end cards).
Usable box: **1680 × 900** at origin (120, 80).

**9:16 (1080 × 1920):** left **60 px**, right **220 px** (the like/comment/share rail),
top **220 px**, bottom **480 px** (caption, handle, audio ticker, CTA).
Usable box: **800 × 1220** at origin (60, 220). Put the hero inside **y = 480 → 1300**.

### 2.2 The handmade grid

An 8 px grid still governs *spacing* — it is invisible and it is what keeps the frame from
feeling accidental. What it does **not** govern is rotation or micro-position.

- **Spacing ramp:** 8 / 16 / 24 / 32 / 48 / 64 / 96 / 128. Nothing between rungs.
- Gaps: label→value **16 px**; within a group **24 px**; between groups **64 px**.
- Card/panel padding: **40 px** (16:9), **32 px** (9:16). Hand-drawn edges need more air than
  vector edges do — never below 32 px.
- **Optical, not mathematical, centering.** Hand-cut shapes have uneven visual mass. Center by
  eye, then verify at 25% zoom.

### 2.3 The imperfection budget

Deliberate, bounded, applied to every element. Values from a **seeded** PRNG so renders repeat.

| Property | Range | Never |
|---|---|---|
| Rotation | **±0.5° to ±2.5°** | Exactly 0°. Above 4° (reads as a mistake, not a choice) |
| Position offset from grid | **±6 px** | Above 12 px |
| Scale variance between similar pieces | **0.94 – 1.06** | Every piece identical |
| Baseline of hand-lettered lines | **±4 px** per line | Perfectly flat |

Rule: adjacent elements must not share the same rotation sign. If one leans left, its neighbor
leans right. Uniform tilt reads as a filter, which is worse than no tilt at all.

---

## 3. Typography

### 3.1 Families and roles

| Role | Family | Used for |
|---|---|---|
| **Display / labels** | **Her marker font** | Titles, chapter cards, callouts, arrows' labels, numbers, key terms |
| **Text** | **Work Sans** (500 / 600) | Burned captions, definitions, source lines, anything over 12 words |
| **Editorial (optional)** | **Fraunces** (soft/wonk axes up) | Chapter cards and pull quotes only, if a serif is wanted |

Two families on screen at once, maximum. The marker font carries the personality; the text face
exists so the marker font never has to do a job it will fail at.

**Hard rule: the marker font is never used below 40 px @ 1080p, and never for captions.**
Marker strokes have inconsistent weight; at caption size and after YouTube's transcode they
turn to mush. Captions are the one place where neutral and legible beats characterful.

### 3.2 Engineering her handwriting font (read before she finishes it)

The single tell that kills a handwriting font is **the same glyph appearing twice, identically,
in the same word.** Real handwriting never repeats. Build the font to solve this:

- **3–5 alternates per letter**, minimum for the high-frequency ones (e a o s t n r i l).
  Also alternate the digits — a recipe video is full of numbers.
- Wire them with **`calt` (contextual alternates)** to auto-rotate so `SUCCESS` never shows two
  matching `S`s side by side. Ship with `calt` on by default; the pipeline will not remember to
  enable it.
- **Draw at scale.** Real marker on real paper, letters ~50 mm tall, scanned at **1200 dpi**,
  bitonal-threshold *after* review, not before. Keep bleed, skips, and chisel-edge variation —
  those artifacts are the value. Do not smooth the outlines.
- **Loose spacing.** Hand block lettering is not tightly kerned. Set generous sidebearings and
  kern only the pairs that actually collide (`LT`, `AV`, `To`, `Ya`). Over-kerning makes it
  look like a font, which defeats the point.
- **Include the punctuation she actually uses:** `– — " " ' ' … × ° ÷ ½ ¼ ¾ % + = →`
  plus `°C °F`. Missing glyphs force a fallback font mid-word and it is instantly visible.
- **Build a second weight only if she draws one.** Never let software generate a bold —
  faux-bold on a marker font looks like a smudge. `font-synthesis: none;` globally.
- Ship as **WOFF2, embedded locally.** Never a CDN — a headless renderer that can't reach the
  network silently falls back to Times and nobody notices until the render is done.

### 3.3 Scale (px @ 1920×1080 / @ 1080×1920)

| Role | Font | 16:9 | 9:16 | Tracking | Leading |
|---|---|---|---|---|---|
| Display (title card) | Marker | 120 | 104 | +0.01em | 1.10 |
| H1 (chapter) | Marker | 84 | 84 | +0.01em | 1.15 |
| H2 (callout / key term) | Marker | 60 | 64 | +0.02em | 1.20 |
| Label / arrow text | Marker | 44 | 52 | +0.03em | 1.25 |
| Body / definition | Work Sans 500 | 34 | 42 | 0 | 1.45 |
| Burned caption | Work Sans 600 | 54 | 62 | +0.005em | 1.25 |
| Source / footnote | Work Sans 500 | 24 | 28 | +0.01em | 1.40 |

**Floors:** marker **40 px**, Work Sans **24 px** @ 1080p. Below that it does not survive
480p transcode or a phone screen — if it must be smaller, it belongs in the description.

Hand lettering needs *more* tracking than a typeface, not less — the strokes are irregular and
letters collide. Positive tracking throughout; never tighten.

### 3.4 Setting rules

- **Measure:** 22–36 characters per line for marker, 28–42 for Work Sans (16:9). Marker runs
  shorter because irregular letterforms fatigue faster. Set `max-width` in `ch`.
- **Left-align** everything except title cards and single-line stat callouts.
  Never justify. Never center a paragraph over two lines.
- **No widows, no orphans.** Rebreak by hand or with `text-wrap: balance`.
- **Sentence case** for the marker font. ALL CAPS block lettering is fine *if that's how she
  letters* — but then commit to it everywhere, never mix.
- Real typography only: `–` ranges, `—` breaks, curly quotes, `…`, `4 g` with a non-breaking
  space, `×` not `x`, `°C` not `C`.
- No trailing periods on titles, chapter cards, or labels.
- **Tabular numerals** on Work Sans for anything that counts or aligns:
  `font-variant-numeric: tabular-nums;`
- Max **three** hierarchy levels and **five** list items visible at once. Marker type is loud;
  it hits its density ceiling faster than a neutral face does.

---

## 4. Color, texture, and depth

### 4.1 Palette — Sage & Oat

| Token | Hex | Role |
|---|---|---|
| `--bone` | `#F2EDE1` | **Primary surface.** Paper white. The default background |
| `--oat` | `#E8DFC8` | Secondary surface, cards, alternate background |
| `--kraft` | `#CBB893` | Cardboard mid-tone. The material color |
| `--sage` | `#8A9A7B` | Primary structural color — diagram fills, brackets, rules |
| `--moss` | `#5C6B4F` | Deep sage. Dark surfaces, secondary text on light |
| `--rust` | `#A5613F` | **The accent.** Emphasis, the one thing that matters in a frame |
| `--walnut` | `#4A3C2E` | **Primary text.** Marker ink. Warm dark |
| `--ink` | `#2B241D` | Deepest value. Dark-mode surface, heavy marker |
| `--stone` | `#8B8377` | Muted text, source lines, de-emphasis |

**Never `#000000` and never `#FFFFFF`.** Pure black and pure white do not exist on paper, in a
kitchen, or in daylight. They are the fastest way to make a warm frame look computer-generated.
Text is `--walnut`. Highlights roll off before paper white.

**Never introduce a hue outside this set.** No blue, no teal, no magenta, no neon. If a diagram
needs a fourth color, it needs fewer elements instead. The one permitted exception is the
*natural* color of real food in b-roll, which is graded but never palette-forced.

### 4.2 Ratio discipline — 70 / 20 / 10

70% warm neutrals (`bone`, `oat`, `kraft`) · 20% greens (`sage`, `moss`) · **10% maximum `rust`.**
Rust is a scalpel: it marks the single most important thing in the frame. If more than a tenth
of the frame is rust, nothing is emphasized.

### 4.3 Texture — the non-negotiables

- **Every background is a scanned surface** from `assets/textures/`. Never a flat fill,
  never a CSS gradient, never generated noise.
- **Grain pass on every graphic composition:** a real flat-scanned paper grain layer, blend mode
  `multiply`, **8–14% opacity**. This is the glue that makes digitally-placed elements sit in the
  same world. Apply once, at the top of the graphic stack, under the captions.
- **Banned:** SVG `feTurbulence`, CSS noise functions, procedural grain, "paper texture" from a
  generator. They have a machine-regular frequency signature and the eye catches it immediately.
- **Composite in float, and premultiply alpha before any resample.** Scaling or rotating a
  cutout with straight alpha drags the transparent region's RGB into the feathered edge, which
  puts a dark fringe on exactly the torn edges §1.3 exists to protect. Integer multiply and
  blend truncate, which drives the darkest channels to `#000000`. Both are invisible by eye and
  only show up in a numeric check. See `style_guide.md` [S-011].
- Vignette: very slight, warm, ≤ 6%. Off-center by 3–5% — a perfectly centered vignette is a filter.

### 4.4 Depth — nothing sits flat

Every cutout gets a **contact shadow**:

```css
/* warm, soft, offset down-right, never pure black */
filter: drop-shadow(5px 7px 14px rgba(74, 60, 46, 0.26));
```

- Offset **4–8 px**, blur **10–20 px**, opacity **20–30%**, color `--walnut` at low alpha.
- **Shadow direction is constant across the entire video** — pick down-right and never vary it.
  Inconsistent shadow direction is the #1 giveaway of composited fakery.
- **Maximum three depth planes:** surface (background) → cutouts → foreground prop or hand.
  A fourth plane turns into collage mush.
- Elements that are meant to be *on* the paper (marker strokes, drawn arrows) get **no shadow** —
  they're ink, not objects. Elements that are *cut* (cardboard) always get one.
- **Banned:** glow, bevel, emboss, inner shadow, `backdrop-filter`, glassmorphism, any glossy
  or specular highlight, rounded-rect "cards" with uniform radius. Depth comes from real shadow
  and real overlap.

---

## 5. Motion — stop-motion, on 2s

### 5.1 The core timing rule

Master is **23.976 fps**. Graphics **step on 2s** — a new position every 2nd frame, **~12
unique positions per second.** Everything in the graphic layer obeys this.

```css
/* every cutout transition */
transition-timing-function: steps(N, end);   /* never a smooth cubic-bezier */
```

Implement as a quantized clock: `t_step = floor(frame / 2) * 2`. Sample all positions,
rotations, and opacities at `t_step`, never at `frame`. If any element moves on an odd frame,
the illusion breaks and the whole composition reads as After Effects.

**Sampling on the step is not sufficient on its own — every phase boundary has to land on a
step too.** Place, hold, and remove run back to back, and each phase counts from its own start.
A hold of 47 frames is 23.5 steps, so the exit begins half a step out of phase and the entire
pull-off lands on odd frames. Round every phase length up onto the step grid before using it;
**up**, not to nearest, because §5.4 hold is a floor. See `style_guide.md` [S-010].

**Live-action footage, camera moves, and captions stay at full 23.976.** Only the graphic layer
steps. This contrast is what makes the graphics feel like objects in a different material
rather than a stylistic filter over everything.

### 5.2 Idle jitter — even when nothing is happening

Real stop-motion is never perfectly still, because a human hand touched the set between frames.
Every graphic element, including static ones, carries a continuous micro-jitter:

| Property | Amplitude | Resample |
|---|---|---|
| x / y | **±1.5 px** | every 2 frames |
| rotation | **±0.4°** | every 2 frames |
| scale | **±0.4%** | every 4 frames |

Seeded PRNG, deterministic per element. Different seed per element — synchronized jitter looks
like an earthquake. **A perfectly static graphic is a bug.**

### 5.3 Entrance and exit vocabulary

Objects are **placed and removed**, not faded.

- **Place:** arrive from ~40 px above with a **2-frame settle overshoot**, total **6–10 frames**
  (250–420 ms). Slight rotation change on arrival (3–5°) so it looks set down, not slid in.
- **Pop-on** (2–3 frames, no movement) is the alternate. Use for small labels and marks.
- **Remove:** pulled off in a consistent direction over 4–6 frames, or a hard cut on a beat.
- **Marker text draws on** stroke by stroke at 12 fps, in writing order, **0.6–1.1 s** for a
  short line. Never a typewriter reveal, never a fade, never letter-scatter.
- **Cross-fades are banned in the graphic layer.** Paper doesn't dissolve. (Cross-dissolves
  between *footage* are fine and are covered in §7.)
- **No motion blur.** Stop-motion has none. If the renderer adds it, turn it off.
- Stagger between sibling elements: **4 frames** (~167 ms), capped at 5 items.
- Animate only `transform`, `opacity`, and `clip-path`. Never `width`, `height`, `top`, `left`,
  `filter`, or `box-shadow`.

### 5.4 Hold time

```
hold_seconds = max(1.6, (word_count / 2.8) + 0.8)
```

2.8 words/second — slower than the flat-graphic standard, because the viewer is decoding
hand lettering *and* listening. A 10-word callout holds **4.4 s** minimum. If the edit can't
afford the hold, the graphic doesn't belong there.

Leave **≥ 250 ms of clean frame** between one graphic's exit and the next one's entrance.
Never overlap them.

### 5.5 Banned motion

Spin-in, flip, cube, wipe, page curl, glitch, VHS, scanlines, light leaks (unless shot in-camera),
lens flare, particle drift, floating/bobbing loops, infinite pulse, parallax on a flat cutout,
zoom-punch on every cut, and any smooth `ease-in-out` applied to a physical object.
Camera shake only if the source footage has it.

---

## 6. Component specifications

**6.1 Chapter / title card** — Full-frame scanned surface (`kraft` or `bone`). Marker display type
at 120 px, left-aligned at column 2, optically centered vertically (~46%, not 50%). Optional
`rust` underline stroke that draws on 4 frames after the text lands. Hold ≥ 1.6 s.

**6.2 Lower third** — Left margin, baseline at y = 820 (16:9). A cardboard strip cutout as the
backing plate, marker name at 60 px, Work Sans role beneath at 34 px in `--stone`.
Places in over 8 frames, holds per §5.4, pulls out left. Max 6 s. Never repeated per speaker.

**6.3 Key-term callout** — A small cardboard card, the term in marker at 60 px `--walnut`, a
`rust` hand-drawn circle or underline that draws on after the card settles. This is the primary
teaching graphic; it should appear the moment she says the term, not before.

**6.4 Diagram (cell, molecule, pathway)** — Built from cutouts, assembled piece by piece **in
sync with the narration**, never all at once. Each piece places on 2s with 4-frame stagger.
Arrows are drawn marker strokes that animate on. **Never render a molecular structure with a
chemistry library** — she draws it. Max 5 labeled elements; split into two beats if more.

**6.5 Scale / gauge (thermometer, timer, pH)** — A physical cardboard gauge with a marker
indicator that steps along it on 2s. Always label both ends and the target zone. For the yeast
video: proofing window, the temperature where yeast dies, fermentation timeline.

**6.6 Comparison ("what most people do" vs "what works")** — Two cards, side by side, placed
left-then-right with 6-frame stagger. The wrong one gets a hand-drawn `rust` ✗; the right one a
`moss` ✓. Never color-code with red/green — use `rust` and `moss`, the palette does the work.

**6.7 Captions (native Final Cut)** — The pipeline writes an `.itt` sidecar from the WhisperX
timings; captions are real FCP caption objects, styled in Final Cut, not a rendered layer.
Two lines max, ≤ 36 characters per line — **the pipeline decides the line breaks**, not FCP's
auto-wrap, so they break on sense rather than on width. Position them at baseline y = 940
(16:9) / y = 1300 (9:16 — above the platform UI band, *not* at the bottom), Work Sans 600 at
54/62 px, `--bone` text on a `rgba(43,36,29,0.82)` plate. **Captions cut, never slide, and
never step on 2s.**

> **Tradeoff, chosen deliberately:** native captions cannot do the word-level `rust` highlight.
> FCP has no karaoke fill, and faking it means one caption object per word — unmanageable on a
> twenty-minute video. Editable text beat the highlight. If the highlight ever matters more,
> set `CAPTION_MODE = "burn"` in `config.py` and Stage 5 will render it as an alpha layer
> instead. See `style_guide.md` [S-005].

**6.8 Data and charts** — Bars are cut cardboard strips, not rendered rectangles. Direct-label on
the plot; no legends. Y-axis starts at zero. No pie charts. Every chart carries a source line at
24 px in `--stone`. **Never invent a number or fabricate a plausible trend** — if it isn't in the
script or a cited source, it doesn't get rendered. She's a scientist; the graphics have to earn
that.

---

## 7. Camera, lighting, and grade

Polish lives here. This is where "homemade" has to stop and "professionally shot" has to start.

- **Two-camera minimum.** A-cam wide/medium locked, B-cam tighter at ~30–45° off-axis so cuts are
  motivated. Match white balance and picture profile between bodies before every shoot.
- **Light soft and large.** One big key (window or 3×3 diffusion) at 45°, negative fill opposite,
  practicals in frame at 2700–3200 K for warmth. Kitchen overheads off — they're green and flat.
- **Shoot flat-ish, grade to the palette.** Lift blacks to **4–6 IRE**, roll highlights off at
  **90–94 IRE**. **Never clip to pure white** — a blown highlight is the single most "rendered"
  looking thing in a warm frame.
- **Grade direction:** warm the shadows toward `--walnut`, desaturate cyans and blues hard
  (they fight the palette), protect skin tones, let greens sit slightly toward `--sage`.
  Build one LUT and apply it to every shot in the channel.
- **Food is shot honestly.** Real steam, real crumb, real bubbles. Macro on fermentation is the
  whole reason to watch a yeast video — shoot it long, shoot it close, shoot it in focus.
- Slight halation on speculars is welcome. **Digital bloom and glow are not.**
- Frame with the safe zones from §2.1 in mind — leave the lower-third and caption regions clear
  of important action at *shoot* time, not in the edit.

---

## 8. Audio

Audio is where "AI-made" is decided faster than in any visual. Budget real time here.

- **Dialogue: −16 LUFS integrated, true peak −1.5 dBTP.** High-pass at 80 Hz, gentle de-ess,
  3:1 compression, light limiting. Never over-processed — pumping and heavy noise reduction give
  voice a synthetic warble that reads as generated.
- **Room tone under every cut.** Record 60 s of it at every location. Dead digital silence between
  sentences is an unmistakable machine-edit tell.
- **Trim silences to 120–180 ms of breath, never to zero.** Removing every pause is exactly what
  makes an auto-edit sound like an auto-edit. The pipeline's Stage 2 must respect this floor.
- **Foley is the secret weapon.** Every graphic placement gets a real sound: cardboard tap, paper
  slide, marker squeak, pencil scratch. Record a foley library once — 30 minutes of table sounds
  buys the entire channel's credibility.
- **Banned:** stock whoosh, riser, impact, sub-drop, "cinematic boom," and any transition SFX from
  a pack. If it came from a sound-effects library labeled "modern," it doesn't go in.
- **Music:** acoustic and analog — upright bass, brushed drums, felt piano, fingerpicked guitar,
  light vibraphone. **No synth pads, no lofi beats, no corporate ukulele.** Sit the bed **13 dB
  under the voice, measured in the 200 Hz – 4 kHz band**, and cut the music entirely under the
  most important sentence of each chapter. Both halves of that are load-bearing: matched
  full-band, a bass-heavy track sets its own level from energy a phone never reproduces, which
  put an audible bed 7 dB below where the number claimed. The figure was −20 dB here until
  2026-08-12 — never checked by ear, and inaudible; 10 dB was audible but sat on top of her.
  See [S-022], [S-025]. A static level, not a sidechain duck: continuous narration with 0.34 s
  pauses never lets a ducker recover.
- J-cuts and L-cuts on every location or camera change. A hard sync cut is a visible seam.

---

## 9. Structure and pacing

- **Hook, 0–15 s.** A concrete claim about a specific thing home cooks get wrong, plus a visual
  promise of what they'll see. Never "hey guys, welcome back." Never a logo sting over 2 s —
  ideally none at all.
- **First graphic inside 30 s.** It establishes the visual language before the viewer decides.
- **Chapter structure**, each opening on a title card (§6.1) and each answering one question.
- **Pattern interrupt every 20–40 s:** camera change, graphic, b-roll, location, or a macro insert.
  Track this explicitly — a 60-second unbroken talking head loses the audience regardless of content.
- **Show the failure before the fix.** For yeast: the dead starter, the dense loaf, the water that
  was too hot. Concrete failure is the hook that abstract chemistry can't provide.
- **Outro under 20 s:** land the single takeaway, name the one next action, end. No begging,
  no five-link outro card, no fade to a wall of thumbnails.

---

## 10. Anti-AI checklist — reject the render if any is true

- [ ] Any procedural/CSS/SVG-generated noise or texture instead of a real scan
- [ ] Any flat color fill or gradient standing in for a material
- [ ] `#000000` or `#FFFFFF` anywhere in the graphics
- [ ] A color outside the §4.1 tokens
- [ ] Rust covering more than ~10% of the frame
- [ ] An element at exactly 0° rotation, or perfectly centered mathematically
- [ ] A vector-crisp edge on something that should be cut or torn
- [ ] A cutout with no contact shadow, or a shadow in a different direction than the rest
- [ ] Pure-black shadow, or any glow / bevel / gloss / `backdrop-filter`
- [ ] Graphic motion that isn't stepped on 2s, or a graphic with no idle jitter
- [ ] Motion blur on a graphic element
- [ ] A cross-fade in the graphic layer
- [ ] Smooth `ease-in-out` on a physical object
- [ ] The same marker glyph repeating identically in a word (`calt` is off)
- [ ] Marker font below 40 px, or any text below 24 px @ 1080p
- [ ] A stock whoosh, riser, or impact on any transition
- [ ] Any silence trimmed below 120 ms, or a cut with no room tone under it
- [ ] A clipped white highlight in the grade
- [ ] Hold time shorter than the §5.4 formula
- [ ] More than 3 hierarchy levels, 5 list items, or 3 depth planes
- [ ] A chart without a source, or with a number not traceable to the script
- [ ] Anything a chemistry or charting library drew instead of her hand

---

## 11. Token block — paste into every template

```css
:root {
  /* palette — sage & oat */
  --bone:#F2EDE1; --oat:#E8DFC8; --kraft:#CBB893;
  --sage:#8A9A7B; --moss:#5C6B4F; --rust:#A5613F;
  --walnut:#4A3C2E; --ink:#2B241D; --stone:#8B8377;

  /* semantic */
  --bg:var(--bone); --fg:var(--walnut); --fg-muted:var(--stone);
  --accent:var(--rust); --structure:var(--sage);
  --shadow: 5px 7px 14px rgba(74,60,46,.26);
  --surface-img: url("../assets/textures/kraft_4k.jpg");
  --grain-img:   url("../assets/textures/paper-grain_flat.png");  /* multiply @ 8–14% */

  /* space (8px ramp) */
  --s1:8px; --s2:16px; --s3:24px; --s4:32px; --s5:48px; --s6:64px; --s7:96px; --s8:128px;

  /* safe zones — 16:9 */
  --margin-x:120px; --margin-top:80px; --margin-bottom:100px;
  /* 9:16 → --margin-x:60px; --margin-right:220px; --margin-top:220px; --margin-bottom:480px; */

  /* type */
  --font-marker:"HerMarker","Work Sans",sans-serif;   /* local woff2, calt ON */
  --font-text:"Work Sans","Helvetica Neue",Arial,sans-serif;
  --fs-display:7.5rem; --fs-h1:5.25rem; --fs-h2:3.75rem; --fs-label:2.75rem;
  --fs-body:2.125rem; --fs-caption:3.375rem; --fs-micro:1.5rem;
  --lh-tight:1.10; --lh-head:1.20; --lh-body:1.45;
  --tr-marker:0.02em; --tr-text:0;

  /* motion — 23.976p master, graphics step on 2s */
  --fps:23.976; --step:2;             /* ~12 unique graphic positions / second */
  --f2:83.4ms;  --f4:166.8ms; --f6:250.3ms; --f8:333.7ms; --f10:417.1ms;
  --d-place:var(--f8); --d-pop:var(--f2); --d-remove:var(--f6);
  --stagger:var(--f4); --rise:40px;
  --jitter-xy:1.5px; --jitter-rot:0.4deg;
}

* { box-sizing:border-box; font-synthesis:none; }
html { font-size: calc(100vw / 120); }        /* 16:9; use /45 for 9:16 */
body {
  margin:0; background:var(--bg) var(--surface-img) center/cover no-repeat;
  color:var(--fg); font-family:var(--font-text);
  font-variant-numeric:tabular-nums;
  text-rendering:geometricPrecision; -webkit-font-smoothing:antialiased;
}
.marker { font-family:var(--font-marker); font-feature-settings:"calt" 1; letter-spacing:var(--tr-marker); }
.cutout { filter:drop-shadow(var(--shadow)); }
.ink    { filter:none; }                       /* drawn marks cast no shadow */
.grain  { position:absolute; inset:0; background:var(--grain-img) center/cover;
          mix-blend-mode:multiply; opacity:.11; pointer-events:none; }
```

**Renderer constraints:** deterministic only — seeded PRNG for all jitter, no `Math.random()`,
no `Date.now()`, no network fetches, no `localStorage`. Drive animation from an explicit frame
prop so any frame can be seeked. Export PNG sequence with alpha → **ProRes 4444** — never bake
overlays into a lossy intermediate. Test-read every graphic at **25% zoom**.

**Handoff constraint:** the pipeline **never flattens a master.** It renders each graphic as a
separate ProRes 4444 alpha layer and hands Final Cut an FCPXML with those layers attached as
connected clips at the right timecodes. Every graphic stays independently movable, retimeable,
and deletable in the edit. Anything the pipeline burns in is a decision she can no longer
change, so it burns in nothing.

---

## 12. Review rubric for the Stage 6 "Watch" agent

Extract a frame at the midpoint of every graphic's hold window, plus one frame every 2 s of
runtime. Any **fail** sends the shot back; log the reason to `style_guide.md`.

| # | Check | Fail condition |
|---|---|---|
| 1 | Safe zone | Any glyph or cutout bbox outside §2.1 |
| 2 | Contrast | Text < 4.5:1 vs. brightest overlapped pixel (< 3:1 for ≥ 60 px) |
| 3 | Face occlusion | Text bbox intersects a detected face bbox |
| 4 | Hold time | On-screen duration < §5.4 formula |
| 5 | Step timing | Any graphic-layer position change on an odd frame |
| 6 | Idle jitter | A graphic element with zero frame-to-frame delta for > 12 frames |
| 7 | Palette drift | Any sampled graphic pixel > ΔE 6 from the §4.1 tokens |
| 8 | Rust budget | Accent pixels > 12% of frame area |
| 9 | Pure values | Any pixel at `#000` or `#FFF` in the graphic layer |
| 10 | Rotation | Any cutout at exactly 0°, or > 4° |
| 11 | Shadow consistency | Shadow direction differs from the project constant |
| 12 | Type floor | Marker < 40 px or text < 24 px @ 1080p equivalent |
| 13 | Line breaks | Widow/orphan, or measure over the §3.4 max |
| 14 | Grain | Graphic composition missing the grain pass |
| 15 | Density | > 3 hierarchy levels, > 5 list items, or > 3 depth planes visible |
| 16 | Audio floor | Any trimmed silence < 120 ms, or a cut with no room tone |
| 17 | Loudness | Program not within −16 ±1 LUFS, or true peak > −1.5 dBTP |
| 18 | Pattern interrupt | > 45 s without a camera change, graphic, or b-roll cut |
| 19 | Banned effects | Motion blur, cross-fade, glow, blur, or gloss in the graphic layer |
| 20 | Collision | Graphic overlaps the caption band or another active graphic |

**Escalate to human review, never auto-fix:** any scientific claim, number, or chart;
anything involving a person's name or credential; and any composition that fails the same
check twice in a row.

---

## 13. Amendment policy

This file describes *taste*. `style_guide.md` records *corrections*. When a render is sent back,
the correction is logged there immediately, with the frame reference and the reason. If the same
correction appears **twice**, it is promoted into this file as a rule and the `style_guide.md`
entry is marked `PROMOTED`. Rules are never deleted silently — supersede them with a dated note
so past renders stay explainable.

**The one rule that never gets amended:** if a choice would make the video look like a machine
made it, the choice is wrong, even if it is faster, cheaper, and cleaner.
