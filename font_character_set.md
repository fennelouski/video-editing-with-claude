# Character set for the marker font

What to letter, and how many versions of each.

---

## First, a note on 20+ versions

20 is generous — well past the 3–5 that kills the repeated-glyph tell. But 20 versions of `⅞`
is a wasted afternoon, and 20 versions of `e` is the best hour she'll spend on this. So the list
below is **tiered by how often the glyph actually appears**, not by how important it feels.

Two things that make the alternates pay off:

- **Cycle deterministically, not randomly.** The `calt` feature should walk the alternates in
  order rather than picking at random — random selection repeats by chance, which is exactly the
  artifact we're avoiding. With 20 alternates and ordered cycling, a letter can appear 20 times
  before it repeats.
- **Draw them in one sitting, per glyph.** Twenty `e`s drawn across three days in three moods
  will read as three different fonts. Twenty drawn in a row read as one hand.

**Digits deserve the highest counts.** A food-science channel is full of `350°F`, `100%`, `2:00`,
`1100` — repeated digits *inside a single number*, side by side, where a repeat is most visible.

---

## Tier 1 — 20 versions each

**If she letters caps-only** (most block lettering is), do all 26 uppercase at 20 and skip the
lowercase tiers entirely.

| Group | Glyphs | Count |
|---|---|---|
| Digits | `0 1 2 3 4 5 6 7 8 9` | 10 |
| High-frequency lowercase | `e t a o i n s r h l d c u m` | 14 |
| High-frequency uppercase | `A C D E F G H I M N O P R S T W` | 16 |

*Total Tier 1: 40 glyphs × 20 = 800 drawings.* That is the bulk of the work and where all the
payoff is.

## Tier 2 — 8 versions each

| Group | Glyphs |
|---|---|
| Remaining lowercase | `b f g j k p q v w x y z` |
| Remaining uppercase | `B J K L Q U V X Y Z` |
| Core punctuation | `. , ' " ! ? : ; -` |

## Tier 3 — 3 versions each

Everything below appears rarely enough that three is plenty.

### Punctuation and symbols
```
( ) [ ] / – — … & % + = < > * # @ $
```
Note `–` (en dash, for ranges: 75–80°F), `—` (em dash), and a **true minus `−`** drawn distinctly
from the hyphen — in `−20°C` a hyphen reads as a dash and looks like a typo.

### Temperature and measurement
```
° ℃ ℉ ± × ÷ ~ ≈ ≤ ≥ ′ ″
```
`×` matters — `2 × 4` should never be lettered with the letter `x`.

### Fractions — baking runs on these
```
½ ⅓ ⅔ ¼ ¾ ⅛ ⅜ ⅝ ⅞
```

### Chemistry — subscripts and superscripts
```
₀ ₁ ₂ ₃ ₄ ₅ ₆ ₇ ₈ ₉        (H₂O, CO₂, C₆H₁₂O₆)
⁰ ¹ ² ³ ⁴ ⁵ ⁶ ⁷ ⁸ ⁹ ⁺ ⁻    (ions, powers)
```
Without real subscript glyphs, every chemical formula falls back to another font mid-word, and
it is instantly visible. `C₆H₁₂O₆` appears in a yeast video more than once.

### Arrows and reaction symbols
```
→ ← ↔ ⇌ ↑ ↓ ⟶
```
**`⇌` is the important one.** Fermentation, enzyme kinetics, and gluten crosslinking are all
equilibria; a one-way `→` where a `⇌` belongs is a factual error, not a typographic one.

### Greek
```
α β Δ μ λ π
```
α and β for glucose anomers and amylase; Δ for change (ΔT); μ for micro.

### Accented characters — food vocabulary
```
é è ê à â ç ñ ü ö
```
sauté, purée, pâte, crème, jalapeño, Maillard names, brioche.

### Hand-drawn marks — these are graphics, not punctuation
```
✓ ✗
```
Called for by `taste_principles.md` §6.6 (the comparison component). Draw them as glyphs so they
sit on the baseline with the text. **Draw 8 versions of each** — they'll be used constantly.

---

## Practical capture

- **One marker, one sitting, one sheet layout.** If she changes markers mid-set, the stroke
  weight shifts and the font develops a seam.
- **Grid the sheet** with light pencil registration marks — a consistent cell size makes
  auto-segmentation into individual PNGs trivial (see the Claude Code handoff).
- **Label each sheet** in a corner with the glyph and the version range.
- **Scan at 1200 dpi**, bitonal threshold *after* review, never before. Keep bleed, skips, and
  chisel-edge variation — those are the value.
- **Don't smooth the outlines** when vectorising. The wobble is the point.
- **Leave the sidebearings loose.** Hand block lettering isn't tightly kerned; over-kerning makes
  it look like a font, which defeats the exercise.

## Build outputs

**Scans → TTF/woff2 directly. No UFO, and no hand-editing of outlines.** The wobble, the bleed
and the marker skips are the value; a font editor is where they get tidied away. More
importantly, a hand-edited source becomes an artifact that can't be regenerated from the scans,
which breaks the determinism convention the rest of the pipeline is built on — the same input
must always produce the same output.

The consequence: **kerning lives in a checked-in data file**, not in an editor. §3.2 only asks
for the pairs that actually collide (`LT`, `AV`, `To`, `Ya` and similar) — a few dozen entries,
compiled into the feature file at build time. If a glyph comes out wrong, the fix is to rescan
it, not to redraw it in software.

## Totals

| Tier | Glyphs | Versions | Drawings |
|---|---|---|---|
| 1 | 40 | 20 | 800 |
| 2 | 31 | 8 | 248 |
| 3 | ~85 | 3 | ~255 |
| Marks (`✓ ✗`) | 2 | 8 | 16 |
| | | | **~1,320** |

If that's too many, cut Tier 3 to the chemistry subscripts, arrows, `°`, `–`, `−`, `×`, and the
fractions. Everything else can be added later without redrawing anything.
