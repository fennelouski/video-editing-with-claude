"""
molecule.py — a validated structure → explicit 2D positions for her atom and bond cutouts.

    python scripts/molecule.py molecules/glucose-ring.json --check

So she doesn't hand-place 24 atom cutouts for one glucose. The output feeds
`stage5_composite.render_cue()` as an explicit layout, replacing the horizontal
`layout_slots()` distribution.

**This module computes geometry. It never decides chemistry.**

That line is the whole design, and it is drawn exactly where `config.ESCALATE_TO_HUMAN` and
`molecular_kit.md` draw it — "she checks every molecule; the pipeline never adjudicates
chemistry". Bond angles, ring closure, packing and grid snapping are geometry: deterministic,
checkable, safe to compute. *Which atoms bond to which*, what each atom's geometry is, and what
the molecule is called are chemistry, and they arrive already decided or the solver refuses to
run.

Concretely, it will not:

  - expand a SMILES string. That is inference — implicit hydrogens and valence are chemistry —
    and `HANDOFF_claude_code.md` item 4 offers it as an option this deliberately declines.
  - guess an atom's geometry from how many bonds it has. Hybridisation depends on lone pairs
    and resonance, so it is stated per atom or the structure is incomplete.
  - fill in a missing element, dedupe a duplicate id, or drop a bond that names an atom which
    does not exist.
  - run at all on a structure with no recorded reviewer.

A wrong molecule laid out beautifully is the worst thing this pipeline could emit: it is
confident, it is legible, and nothing downstream would catch it. So every refusal below is
loud, and none of them has a fallback.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import cli
import config as C          # noqa: E402
import stepclock as SC      # noqa: E402


# Materials and relative sizes from molecular_kit.md. The palette has no blue and no yellow, so
# atoms are coded by material and mark rather than by hue — which also survives greyscale and
# reads better on a phone.
ATOMS = {
    "C": {"material": "kraft, cut edge",        "mark": "none",           "size": 1.00},
    "H": {"material": "bone card, cut edge",    "mark": "none",           "size": 0.55},
    "O": {"material": "kraft, torn edge",       "mark": "solid rust fill", "size": 0.95},
    "N": {"material": "kraft, cut edge",        "mark": "cross-hatch",    "size": 0.95},
    "S": {"material": "corrugated, flutes",     "mark": "stipple",        "size": 1.15},
    "P": {"material": "bone card, torn edge",   "mark": "concentric ring", "size": 1.10},
}

BONDS = {"single", "double", "triple", "hydrogen", "disulfide", "peptide"}

# Ideal angle *between* two bonds at an atom. Stated per atom in the structure file, never
# inferred: this table only says what each named geometry means.
GEOMETRY = {"tetrahedral": 109.5, "trigonal": 120.0, "linear": 180.0}

# §6.4 — "Max 5 labeled elements; split into two beats if more."
MAX_LABELS = C.MAX_LIST_ITEMS

BOND_UNIT = 1.0             # layout units; scaled to the safe box at the end

# An unfilled template is the likeliest way an unreviewed structure reaches a render, because
# it looks complete. Refusing these by name costs nothing and closes that path.
PLACEHOLDER_MARKERS = ("PLACEHOLDER", "TODO", "TBD", "FIXME", "XXX",
                       "NOT YET REVIEWED", "UNREVIEWED", "YOUR NAME", "EXAMPLE")


class StructureError(Exception):
    """A structure that the pipeline must not guess its way past."""


# --------------------------------------------------------------------------------------
# Validation
# --------------------------------------------------------------------------------------

@dataclass(frozen=True)
class Atom:
    id: str
    element: str
    geometry: str
    label: str = ""


@dataclass(frozen=True)
class Bond:
    a: str
    b: str
    kind: str = "single"


@dataclass(frozen=True)
class Structure:
    name: str
    reviewed_by: str
    reviewed_on: str
    atoms: tuple[Atom, ...]
    bonds: tuple[Bond, ...]
    source: str = ""
    # Depiction notes as recorded in the file — i.e. what she actually had in front of her.
    # None means the field is absent, which is different from an empty list meaning "reviewed,
    # and there were none".
    depiction_notes: tuple[str, ...] | None = None


def load_structure(path: Path) -> Structure:
    """
    Read and validate a structure file. Every failure here is a refusal, never a repair.

    The reviewer fields are not bookkeeping. `config.ESCALATE_TO_HUMAN` lists
    `scientific_claim` and `chart_data`, and a molecular structure is both — so an unreviewed
    file is not a structure the pipeline is allowed to draw, however well-formed it looks.
    """
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise StructureError(f"{path.name} is not valid JSON: {exc}")

    if "smiles" in data and "atoms" not in data:
        raise StructureError(
            f"{path.name} gives a SMILES string and no explicit atoms.\n"
            f"  Expanding SMILES means inferring implicit hydrogens and valence, which is\n"
            f"  chemistry, not geometry — see config.ESCALATE_TO_HUMAN. Write the atoms and\n"
            f"  bonds out explicitly and have her check them. A `smiles` field alongside an\n"
            f"  explicit structure is fine as a label; it is never expanded."
        )

    reviewer = str(data.get("reviewed_by", ""))
    if any(marker in reviewer.upper() for marker in PLACEHOLDER_MARKERS):
        raise StructureError(
            f"{path.name} names its reviewer as {reviewer!r}, which is a placeholder.\n"
            f"  A template copied and not filled in must not draw. Nothing downstream would\n"
            f"  catch it — the layout would be geometrically perfect and chemically unchecked,\n"
            f"  which is the exact failure config.ESCALATE_TO_HUMAN exists to prevent.\n"
            f"  Replace it with who actually checked the structure."
        )

    for required in ("name", "reviewed_by", "reviewed_on", "atoms"):
        if not data.get(required):
            raise StructureError(
                f"{path.name} has no {required!r}.\n"
                f"  A structure is a scientific claim (config.ESCALATE_TO_HUMAN), so it carries\n"
                f"  who checked it and when. The pipeline does not adjudicate chemistry and will\n"
                f"  not draw an unreviewed molecule."
            )
    # `bonds` must be present but may be empty: a single atom on its own is a real thing to
    # draw — the legend card in molecular_kit.md is exactly that.
    if "bonds" not in data:
        raise StructureError(
            f"{path.name} has no 'bonds' key. Use an empty list for a single unbonded atom, so "
            f"that 'no bonds' is something stated rather than something omitted."
        )

    atoms: list[Atom] = []
    seen: set[str] = set()
    for i, raw in enumerate(data["atoms"]):
        aid = str(raw.get("id", "")).strip()
        if not aid:
            raise StructureError(f"{path.name}: atom {i} has no id")
        if aid in seen:
            raise StructureError(
                f"{path.name}: two atoms share the id {aid!r}. Renaming one would change which "
                f"bonds attach where, so this is hers to resolve."
            )
        seen.add(aid)

        element = str(raw.get("element", "")).strip()
        if element not in ATOMS:
            raise StructureError(
                f"{path.name}: atom {aid!r} has element {element!r}, which the kit has no "
                f"disc for. molecular_kit.md builds {', '.join(sorted(ATOMS))}."
            )

        geometry = str(raw.get("geometry", "")).strip()
        if geometry not in GEOMETRY:
            raise StructureError(
                f"{path.name}: atom {aid!r} has no usable geometry ({geometry!r}).\n"
                f"  State one of {', '.join(sorted(GEOMETRY))} per atom. It is not inferred from\n"
                f"  the bond count — hybridisation depends on lone pairs and resonance, which is\n"
                f"  chemistry."
            )
        atoms.append(Atom(aid, element, geometry, str(raw.get("label", "")).strip()))

    bonds: list[Bond] = []
    for i, raw in enumerate(data["bonds"]):
        a, b = str(raw.get("a", "")), str(raw.get("b", ""))
        if a not in seen or b not in seen:
            missing = [x for x in (a, b) if x not in seen]
            raise StructureError(
                f"{path.name}: bond {i} joins {a!r}–{b!r}, but {', '.join(map(repr, missing))} "
                f"is not an atom in this file."
            )
        if a == b:
            raise StructureError(f"{path.name}: bond {i} joins {a!r} to itself")
        kind = str(raw.get("kind", "single"))
        if kind not in BONDS:
            raise StructureError(
                f"{path.name}: bond {a}–{b} is {kind!r}; the kit builds {', '.join(sorted(BONDS))}"
            )
        bonds.append(Bond(a, b, kind))

    recorded_notes = data.get("depiction_notes")
    if recorded_notes is not None and not isinstance(recorded_notes, list):
        raise StructureError(f"{path.name}: 'depiction_notes' must be a list of strings")

    labelled = [a for a in atoms if a.label]
    if len(labelled) > MAX_LABELS:
        raise StructureError(
            f"{path.name}: {len(labelled)} labelled atoms, and §6.4 allows {MAX_LABELS}.\n"
            f"  'Max 5 labeled elements; split into two beats if more.' Drop labels or split\n"
            f"  the diagram — both are editorial calls, not something to solve around."
        )

    return Structure(
        name=data["name"], reviewed_by=data["reviewed_by"], reviewed_on=data["reviewed_on"],
        atoms=tuple(atoms), bonds=tuple(bonds), source=str(data.get("source", "")),
        depiction_notes=None if recorded_notes is None else tuple(str(n) for n in recorded_notes),
    )


# --------------------------------------------------------------------------------------
# Graph
# --------------------------------------------------------------------------------------

def adjacency(s: Structure) -> dict[str, list[str]]:
    adj: dict[str, list[str]] = {a.id: [] for a in s.atoms}
    for bond in s.bonds:
        adj[bond.a].append(bond.b)
        adj[bond.b].append(bond.a)
    return adj


def find_rings(s: Structure) -> list[list[str]]:
    """
    Ring systems, as ordered atom cycles.

    Found from the back edges of a spanning tree: each edge outside the tree closes exactly one
    cycle, and the tree path between its endpoints is that ring. Enough for the molecules in
    `molecular_kit.md` — glucose, benzene rings, the amino acid backbone — and it makes ring
    closure a structural fact rather than something the layout has to approximate.
    """
    adj = adjacency(s)
    parent: dict[str, str | None] = {}
    order: list[str] = []
    rings: list[list[str]] = []

    for start in adj:
        if start in parent:
            continue
        parent[start] = None
        stack = [start]
        while stack:
            node = stack.pop()
            order.append(node)
            for nxt in adj[node]:
                if nxt not in parent:
                    parent[nxt] = node
                    stack.append(nxt)

    tree_edges = {frozenset((k, v)) for k, v in parent.items() if v is not None}
    for bond in s.bonds:
        edge = frozenset((bond.a, bond.b))
        if edge in tree_edges:
            continue
        tree_edges.add(edge)                # each back edge closes one ring
        ring = _tree_path(parent, bond.a, bond.b)
        if ring and len(ring) >= 3:
            rings.append(ring)
    return rings


def _tree_path(parent: dict[str, str | None], a: str, b: str) -> list[str]:
    """The path from a to b through the spanning tree, which closes the ring with edge a–b."""
    up_a, node = [], a
    while node is not None:
        up_a.append(node)
        node = parent.get(node)
    seen = {n: i for i, n in enumerate(up_a)}

    up_b, node = [], b
    while node is not None:
        if node in seen:
            return up_a[:seen[node] + 1] + list(reversed(up_b))
        up_b.append(node)
        node = parent.get(node)
    return []


# --------------------------------------------------------------------------------------
# Layout
# --------------------------------------------------------------------------------------

@dataclass
class PlacedAtom:
    id: str
    element: str
    x: float
    y: float
    rotation: float
    scale: float
    label: str
    asset: str


@dataclass
class PlacedBond:
    a: str
    b: str
    kind: str
    x: float
    y: float
    angle: float
    length: float
    asset: str


@dataclass
class Layout:
    name: str
    reviewed_by: str
    atoms: list[PlacedAtom] = field(default_factory=list)
    bonds: list[PlacedBond] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    @property
    def bbox(self) -> tuple[float, float, float, float]:
        xs = [a.x for a in self.atoms]
        ys = [a.y for a in self.atoms]
        return min(xs), min(ys), max(xs), max(ys)


def _skeleton(s: Structure) -> dict[str, tuple[float, float]]:
    """
    Unit-scale positions, before fitting to the frame.

    Rings are laid out first, as regular polygons, because ring closure is a hard geometric
    constraint and everything else can bend around it. Acyclic neighbours then grow outward at
    the angle each atom's stated geometry calls for, alternating side so a chain zig-zags the
    way a drawn one does.
    """
    adj = adjacency(s)
    rings = find_rings(s)
    pos: dict[str, tuple[float, float]] = {}

    for ring in rings:
        if any(a in pos for a in ring):
            continue        # fused to a ring already placed; grown as substituents below
        n = len(ring)
        radius = BOND_UNIT / (2 * math.sin(math.pi / n))
        for i, atom in enumerate(ring):
            theta = 2 * math.pi * i / n - math.pi / 2
            pos[atom] = (radius * math.cos(theta), radius * math.sin(theta))

    if not pos:
        first = s.atoms[0].id
        pos[first] = (0.0, 0.0)

    # Grow outward. Each newly placed atom is put at the ideal angle from the bond that reached
    # it, on whichever side is emptier — a cheap stand-in for real collision resolution that is
    # sufficient for kit-scale molecules and, importantly, deterministic.
    queue = list(pos)
    while queue:
        node = queue.pop(0)
        px, py = pos[node]
        ideal = GEOMETRY[next(a.geometry for a in s.atoms if a.id == node)]

        placed_neighbours = [n for n in adj[node] if n in pos]
        if placed_neighbours:
            ax, ay = pos[placed_neighbours[0]]
            incoming = math.atan2(py - ay, px - ax)
        else:
            incoming = 0.0

        turn = math.radians(180.0 - ideal)
        side = 1
        for neighbour in adj[node]:
            if neighbour in pos:
                continue
            best = None
            for candidate_side in (side, -side):
                theta = incoming + candidate_side * turn
                cx, cy = px + BOND_UNIT * math.cos(theta), py + BOND_UNIT * math.sin(theta)
                clearance = min(
                    (math.dist((cx, cy), p) for k, p in pos.items() if k != node),
                    default=math.inf,
                )
                if best is None or clearance > best[0]:
                    best = (clearance, cx, cy, candidate_side)
            _, cx, cy, used = best        # type: ignore[misc]
            pos[neighbour] = (cx, cy)
            queue.append(neighbour)
            side = -used                  # alternate, so chains zig-zag
    return pos


def solve(s: Structure, aspect: str = C.DEFAULT_ASPECT, *, seed_key: str = "") -> Layout:
    """
    Positions and rotations for every cutout, on the 8 px grid and inside the safe box.

    The imperfection budget (§2.3) is applied last and deliberately: positions land on the grid
    and are then nudged off it by up to ±6 px, and adjacent atoms take opposite rotation signs
    so the assembly never reads as a filter.
    """
    import stage5_composite as S5

    spec = C.ASPECTS[aspect]
    bx, by, bw, bh = S5.content_box(spec)

    skeleton = _skeleton(s)
    xs = [p[0] for p in skeleton.values()]
    ys = [p[1] for p in skeleton.values()]
    span_x = max(xs) - min(xs) or BOND_UNIT
    span_y = max(ys) - min(ys) or BOND_UNIT

    # Leave room for the discs themselves, which straddle their centre points.
    biggest = max(ATOMS[a.element]["size"] for a in s.atoms)
    pad = BOND_UNIT * biggest
    scale = min(bw / (span_x + pad * 2), bh / (span_y + pad * 2))

    cx = bx + bw / 2 - (min(xs) + span_x / 2) * scale
    cy = by + bh / 2 - (min(ys) + span_y / 2) * scale

    layout = Layout(name=s.name, reviewed_by=s.reviewed_by)
    grid = C.GRID_UNIT
    key = seed_key or s.name

    for i, atom in enumerate(s.atoms):
        raw_x = skeleton[atom.id][0] * scale + cx
        raw_y = skeleton[atom.id][1] * scale + cy
        pose = SC.resting_pose(f"{key}:{atom.id}", neighbor_index=i)
        layout.atoms.append(PlacedAtom(
            id=atom.id, element=atom.element,
            # Snap to the 8 px spacing grid (§2.2), then off it by the §2.3 budget. The grid
            # governs spacing; it explicitly does not govern micro-position.
            x=round(raw_x / grid) * grid + pose.x,
            y=round(raw_y / grid) * grid + pose.y,
            rotation=pose.rotation,
            scale=ATOMS[atom.element]["size"] * pose.scale,
            label=atom.label,
            asset=f"cutout:atom_{atom.element.lower()}",
        ))

    placed = {a.id: a for a in layout.atoms}
    for i, bond in enumerate(s.bonds):
        a, b = placed[bond.a], placed[bond.b]
        dx, dy = b.x - a.x, b.y - a.y
        layout.bonds.append(PlacedBond(
            a=bond.a, b=bond.b, kind=bond.kind,
            x=(a.x + b.x) / 2, y=(a.y + b.y) / 2,
            angle=math.degrees(math.atan2(dy, dx)),
            length=math.hypot(dx, dy),
            asset=f"cutout:bond_{bond.kind}",
        ))

    layout.notes.extend(_angle_notes(s, skeleton))
    _check_depiction_reviewed(s, layout.notes)
    return layout


def depiction_notes(s: Structure) -> list[str]:
    """
    The depiction deviations for a structure, without laying it out.

    Public because there has to be a way to *obtain* the text she is asked to record —
    `molecule.py <file> --notes` prints exactly this, ready to paste.
    """
    return _angle_notes(s, _skeleton(s))


def _check_depiction_reviewed(s: Structure, notes: list[str]) -> None:
    """
    The depiction deviations must be recorded in the file she signed, not only in a log.

    `reviewed_by` already means a human looked at the structure. This makes the angle report
    part of what was in front of her when she did. It matters for one real case: if the video
    is teaching chair conformations or bond angles specifically, a cyclohexane drawn flat at
    120° is exactly the thing under discussion, and she is the only one who can judge whether
    the standard depiction is acceptable there.

    Everywhere else this is a formality — one paste, once per structure — and it is not a new
    review mechanism, just the existing one told the whole truth.
    """
    recorded = list(s.depiction_notes) if s.depiction_notes is not None else None
    if recorded == notes:
        return

    if recorded is None and not notes:
        return          # nothing to see, nothing to record

    lines = [
        f"{s.name}: the depiction notes in the file do not match what the layout produces.",
        "",
        "  `reviewed_by` says a human checked this structure, so the deviations below need to",
        "  have been part of that. Copy them into a `depiction_notes` list and re-check —",
        "  particularly if this diagram is teaching bond angles or ring conformation, where a",
        "  flat hexagon is the subject rather than a convention.",
        "",
        "  What the layout produces:",
    ]
    lines += [f'    "{n}",' for n in notes] or ["    (none)"]
    if recorded:
        lines += ["", "  What the file records:"]
        lines += [f'    "{n}",' for n in recorded]
    raise StructureError("\n".join(lines))


def _angle_notes(s: Structure, pos: dict[str, tuple[float, float]]) -> list[str]:
    """
    Where ring closure forced an angle away from the atom's ideal, and by how much.

    Not a failure. A six-ring of tetrahedral carbons is universally drawn as a hexagon with
    120° interior angles — a planar polygon cannot hold 109.5° and still close — so the
    deviation is the standard depiction rather than an error. It is reported because it is a
    real difference between the drawing and the molecule, and she should see it stated.
    """
    ring_atoms = {a for ring in find_rings(s) for a in ring}
    adj = adjacency(s)
    notes = []
    for atom in s.atoms:
        if atom.id not in ring_atoms:
            continue
        neighbours = [n for n in adj[atom.id] if n in ring_atoms]
        if len(neighbours) < 2:
            continue
        (x, y) = pos[atom.id]
        v = []
        for n in neighbours[:2]:
            nx, ny = pos[n]
            v.append(math.atan2(ny - y, nx - x))
        actual = abs(math.degrees(v[0] - v[1])) % 360
        actual = min(actual, 360 - actual)
        ideal = GEOMETRY[atom.geometry]
        if abs(actual - ideal) > 1.0:
            notes.append(
                f"{atom.id} ({atom.element}) drawn at {actual:.1f}° against a {ideal:.1f}° "
                f"{atom.geometry} ideal — ring closure, the standard depiction"
            )
    return notes


# --------------------------------------------------------------------------------------
# Entry
# --------------------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    cli.preflight()
    ap = argparse.ArgumentParser(description="Lay out a validated molecular structure")
    ap.add_argument("structure", type=Path)
    ap.add_argument("--aspect", default=C.DEFAULT_ASPECT, choices=list(C.ASPECTS))
    ap.add_argument("--out", type=Path)
    ap.add_argument("--notes", action="store_true",
                    help="print the depiction_notes block to paste into the structure file")
    args = ap.parse_args(argv)

    try:
        structure = load_structure(
            cli.resolve_or_exit(args.structure, expect=(".json",), label="structure"))
    except StructureError as exc:
        print(f"! {exc}")
        return 2

    if args.notes:
        notes = depiction_notes(structure)
        print(f"{structure.name} — paste into the structure file and re-check:\n")
        print("  \"depiction_notes\": [")
        for note in notes:
            print(f"    \"{note}\",")
        print("  ]")
        if notes:
            print("\n  These are depiction conventions, not errors — but if this diagram is")
            print("  teaching bond angles or ring conformation, they are the subject.")
        return 0

    try:
        layout = solve(structure, args.aspect)
    except StructureError as exc:
        print(f"! {exc}")
        return 2
    print(f"{structure.name} — reviewed by {structure.reviewed_by} on {structure.reviewed_on}")
    print(f"  {len(layout.atoms)} atoms, {len(layout.bonds)} bonds, "
          f"{len(find_rings(structure))} ring(s)")
    x0, y0, x1, y1 = layout.bbox
    print(f"  bbox {x1 - x0:.0f}x{y1 - y0:.0f} px at ({x0:.0f}, {y0:.0f})")
    for note in layout.notes:
        print(f"  · {note}")

    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps({
            "name": layout.name, "reviewed_by": layout.reviewed_by,
            "atoms": [asdict(a) for a in layout.atoms],
            "bonds": [asdict(b) for b in layout.bonds],
            "notes": layout.notes,
        }, indent=2))
        print(f"  → {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
