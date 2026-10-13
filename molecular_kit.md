# The molecular kit

Physical design elements for the atoms → molecules → proteins → gluten → bread ladder.

---

## The core problem

That explanation spans about **nine orders of magnitude**, from an angstrom to a loaf. The
failure mode isn't ugly graphics — it's the viewer losing track of what scale they're looking at.
So the kit needs two things: a **reusable parts library** so molecules can be assembled rather
than illustrated one at a time, and a **scale grammar** that makes every zoom explicit.

Build a **kit, not artwork.** Twelve reusable atom discs assemble into any molecule in the video.
Twelve bespoke molecule drawings assemble into nothing.

---

## The palette constraint — and why it helps

Chemistry conventionally colour-codes atoms: carbon black, oxygen red, nitrogen blue, sulfur
yellow. **The Sage & Oat palette has no blue and no yellow**, and `taste_principles.md` §4.1
forbids adding them.

Don't fight it. Code atoms by **material and mark** instead of hue:

| Atom | Material | Mark | Relative size |
|---|---|---|---|
| Carbon | Plain kraft, cut edge | unmarked | 1.0 |
| Hydrogen | Bone card, cut edge | unmarked | 0.55 |
| Oxygen | Kraft, **torn** edge | solid rust fill | 0.95 |
| Nitrogen | Kraft, cut edge | marker cross-hatch | 0.95 |
| Sulfur | Corrugated (flutes showing) | marker stipple | 1.15 |
| Phosphorus | Bone card, torn edge | concentric ring | 1.1 |

This is more legible on a phone than colour is, it survives greyscale, and it's more tactile —
the corrugation on sulfur is visible as *texture*, not decoration. Make one **legend card** early
and reuse it in every video; the audience learns it once.

Sulfur earns the loudest treatment because **disulfide bonds are the whole story of gluten**.

---

## Layer 1 — Atoms

- Discs, **6 elements × 12 copies each**. Cut a lot; a single glucose molecule is 24 atoms.
- Consistent diameters per the table above. Cut one master template per size so they match.
- Punch a small centre hole in every disc — see bonds below.

## Layer 2 — Bonds

| Bond | Build |
|---|---|
| Single | Short kraft strip, square ends |
| Double | Two parallel strips, 4 mm apart |
| Triple | Three strips |
| Hydrogen bond | **Drawn**, not cut — dotted marker line, no shadow (§4.4: ink casts none) |
| Disulfide | Corrugated strip, visibly heavier than a single bond |
| Peptide bond | Single strip with a marker highlight ring |

**Use brass paper fasteners (brads) through the centre holes.** Bonds rotate. A brad lets a bond
actually pivot between exposures, which means conformational change is animated by moving the
real object rather than faked in software. This is the single highest-value trick in the kit.

## Layer 3 — Small molecules

Pre-assemble and keep intact, mounted on backing card so they don't fall apart between shoots:

- Water, CO₂, ethanol, glucose (chain **and** ring forms — the ring is what matters for starch),
- Maltose, a generic amino acid, ATP (simplified).

Glucose ring form should be built at least twice so you can show two joining.

## Layer 4 — Amino acids

Cut as **interlocking puzzle pieces**: a common backbone shape with a tab on one side and a notch
on the other, plus a variable side-chain that plugs into the top.

This is the best metaphor in the kit — the pieces physically only join one way, which *is* what a
peptide bond is. Build:

- **12 backbone pieces** (identical),
- **8 side chains**: one small (glycine), one bulky hydrophobic, one polar, one acidic, one
  basic, one aromatic, and **two cysteines** with a visible sulfur disc,
- **Glutamine** specifically — gluten is loaded with it, and its side chain drives the hydrogen
  bonding that makes dough sticky.

## Layer 5 — Protein structure

- **Primary:** a chain of 12 linked backbone pieces on a ribbon or cord so it drapes naturally.
- **Secondary:** a paper strip coiled into an α-helix (wrap around a dowel, let it hold the
  curl); a folded-fan β-sheet.
- **Tertiary:** the coiled strip folded and clipped into a compact blob.
- **Quaternary:** two or three blobs held together.

Build the helix and sheet from the **same strip stock** as the primary chain, so it's visually
obvious it's the same molecule folding, not a new object.

## Layer 6 — Gluten specifically

This is the video, so it gets its own dedicated pieces:

- **Glutenin** — long, springy, made from a coiled strip; the elastic one. Build 4.
- **Gliadin** — compact, rounded blob; the extensible/sticky one. Build 6.
- **Disulfide crosslinks** — corrugated connectors with brads, joining glutenin to glutenin.
  Build 10; this is the mechanism.
- **Hydrogen bonds** — drawn dotted lines between gliadins, added with marker on the surface.
- **Development sequence** — the network forming, as **6 progressive states** on separate
  backing cards: dry flour, hydrated, shaggy, kneaded 2 min, kneaded 8 min, over-kneaded/torn.
  Shoot all six the same way so they cut together as a build.
- **Water molecules** — 12 small ones, to scatter between the proteins during hydration.

## Layer 7 — Scale bridges

The device that keeps the viewer oriented. Pick **one** and use it every time:

- A **hand-drawn magnifier frame** that lands on a region and the next shot fills the screen
  with what was inside it, or
- **Nested squares** — a small marker square drawn on the wide view, matching the frame edge of
  the next shot.

Also cut a **scale bar card** with a lettered magnitude (`1 nm`, `1 μm`, `1 mm`) that sits in the
same corner every time. Changing only the number between shots is what sells the zoom.

## Layer 8 — Familiar food

Where the ladder lands. Photograph, don't build:

- Flour on the counter, dough at each development stage, a windowpane test, crumb cross-section,
  the finished loaf.

Shoot the **failures first** — over-kneaded, under-proofed, collapsed. They're far harder to
reproduce on demand than the good version, and they're the hook.

---

## Build order

1. Legend card + atom discs + bonds — nothing else works without these.
2. Glucose (both forms), water, CO₂, ethanol.
3. Amino acid pieces + the protein-structure strips.
4. The gluten set and the 6-state development sequence.
5. Scale bridges.
6. Food photography.

Steps 1–3 are reusable across every video she'll ever make. Step 4 is specific to this one.

---

## Two rules that still apply

**Accuracy is escalated, never automated.** `config.ESCALATE_TO_HUMAN` covers scientific claims,
numbers, and structures. She checks every molecule; the pipeline never adjudicates chemistry.

**Capture per §1.2.** Every piece shot 4–6 times with a millimetre of movement between frames,
overhead, flat-lit, on mid-grey seamless, grey card in the first frame of every session. Those
variants become the stop-motion jitter — real, not simulated.
