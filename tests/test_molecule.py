"""
Molecule layout invariants (molecular_kit.md; taste_principles §2.1, §2.2, §2.3, §6.4).

Half this file is about what the solver *refuses*. That is the point of it: geometry is safe to
compute, chemistry is not, and `config.ESCALATE_TO_HUMAN` puts structures firmly in the second
category. A wrong molecule laid out beautifully is the worst output this pipeline could produce
— confident, legible, and invisible to every check downstream — so each refusal is tested as
carefully as the geometry.
"""

from __future__ import annotations

import json
import math

import pytest

import config as C
import molecule as M


REVIEWED = {"reviewed_by": "her", "reviewed_on": "2026-08-11"}


def write(tmp_path, name="m.json", **overrides):
    data = {
        "name": "test",
        **REVIEWED,
        "atoms": [
            {"id": "C1", "element": "C", "geometry": "tetrahedral"},
            {"id": "C2", "element": "C", "geometry": "tetrahedral"},
            {"id": "O1", "element": "O", "geometry": "tetrahedral"},
        ],
        "bonds": [
            {"a": "C1", "b": "C2", "kind": "single"},
            {"a": "C2", "b": "O1", "kind": "single"},
        ],
    }
    data.update(overrides)
    path = tmp_path / name
    path.write_text(json.dumps(data))
    return path


def ring(tmp_path, n=6, geometry="tetrahedral"):
    """
    A closed ring, with its depiction notes already recorded.

    Recording them is what a reviewed structure looks like: the 109.5° → 120° deviation a flat
    hexagon forces was in front of her when she signed. Tests for the *unrecorded* case are
    separate and explicit, below.
    """
    atoms = [{"id": f"C{i}", "element": "C", "geometry": geometry} for i in range(n)]
    bonds = [{"a": f"C{i}", "b": f"C{(i + 1) % n}", "kind": "single"} for i in range(n)]
    path = write(tmp_path, "ring.json", atoms=atoms, bonds=bonds)
    notes = M.depiction_notes(M.load_structure(path))
    return write(tmp_path, "ring.json", atoms=atoms, bonds=bonds, depiction_notes=notes)


# --------------------------------------------------------------------------------------
# Refusals — chemistry is escalated, never automated
# --------------------------------------------------------------------------------------

def test_unreviewed_structure_is_refused(tmp_path):
    """
    config.ESCALATE_TO_HUMAN lists `scientific_claim` and `chart_data`; a structure is both.
    A well-formed file with no reviewer is still not one the pipeline may draw.
    """
    path = write(tmp_path, reviewed_by="", reviewed_on="")
    with pytest.raises(M.StructureError) as exc:
        M.load_structure(path)
    assert "reviewed_by" in str(exc.value)
    assert "adjudicate chemistry" in str(exc.value)


def test_smiles_is_never_expanded(tmp_path):
    """
    HANDOFF item 4 offers SMILES as an input option, and this declines it. Expanding SMILES
    means inferring implicit hydrogens and valence — chemistry, done silently, at scale.
    """
    path = tmp_path / "s.json"
    path.write_text(json.dumps({"name": "glucose", **REVIEWED,
                                "smiles": "OC[C@H]1OC(O)[C@H](O)[C@@H](O)[C@@H]1O",
                                "bonds": []}))
    with pytest.raises(M.StructureError) as exc:
        M.load_structure(path)
    assert "SMILES" in str(exc.value)
    assert "ESCALATE_TO_HUMAN" in str(exc.value)


def test_smiles_alongside_an_explicit_structure_is_allowed(tmp_path):
    """As a label it is harmless; it is only ever a problem when it is the *source* of truth."""
    path = write(tmp_path, smiles="CCO")
    assert M.load_structure(path).name == "test"


def test_missing_geometry_is_refused_not_inferred(tmp_path):
    """
    Hybridisation depends on lone pairs and resonance. Deducing it from the bond count would be
    the solver quietly deciding chemistry, and it would be wrong for exactly the interesting
    cases — water's oxygen among them.
    """
    path = write(tmp_path, atoms=[
        {"id": "C1", "element": "C"},
        {"id": "C2", "element": "C", "geometry": "tetrahedral"},
    ], bonds=[{"a": "C1", "b": "C2"}])
    with pytest.raises(M.StructureError) as exc:
        M.load_structure(path)
    assert "geometry" in str(exc.value)
    assert "not inferred" in str(exc.value)


def test_unknown_element_is_refused(tmp_path):
    path = write(tmp_path, atoms=[
        {"id": "X1", "element": "Fe", "geometry": "tetrahedral"},
        {"id": "C1", "element": "C", "geometry": "tetrahedral"},
    ], bonds=[{"a": "X1", "b": "C1"}])
    with pytest.raises(M.StructureError) as exc:
        M.load_structure(path)
    assert "Fe" in str(exc.value)


def test_bond_to_a_nonexistent_atom_is_refused(tmp_path):
    path = write(tmp_path, bonds=[{"a": "C1", "b": "C99"}])
    with pytest.raises(M.StructureError) as exc:
        M.load_structure(path)
    assert "C99" in str(exc.value)


def test_duplicate_atom_ids_are_refused(tmp_path):
    path = write(tmp_path, atoms=[
        {"id": "C1", "element": "C", "geometry": "tetrahedral"},
        {"id": "C1", "element": "O", "geometry": "tetrahedral"},
    ], bonds=[])
    with pytest.raises(M.StructureError) as exc:
        M.load_structure(path)
    assert "share the id" in str(exc.value)


def test_unknown_bond_kind_is_refused(tmp_path):
    path = write(tmp_path, bonds=[{"a": "C1", "b": "C2", "kind": "ionic"}])
    with pytest.raises(M.StructureError):
        M.load_structure(path)


def test_self_bond_is_refused(tmp_path):
    path = write(tmp_path, bonds=[{"a": "C1", "b": "C1"}])
    with pytest.raises(M.StructureError):
        M.load_structure(path)


def test_too_many_labels_is_refused(tmp_path):
    """§6.4 — max 5 labelled elements; split into two beats if more. An editorial call."""
    over = C.MAX_LIST_ITEMS + 1
    atoms = [{"id": f"C{i}", "element": "C", "geometry": "tetrahedral", "label": f"atom {i}"}
             for i in range(over)]
    path = write(tmp_path, atoms=atoms, bonds=[
        {"a": f"C{i}", "b": f"C{i + 1}"} for i in range(over - 1)])
    with pytest.raises(M.StructureError) as exc:
        M.load_structure(path)
    assert "§6.4" in str(exc.value)


@pytest.mark.parametrize("reviewer", [
    "PLACEHOLDER — not yet reviewed", "TODO", "TBD", "your name here",
    "example reviewer", "FIXME: ask her",
])
def test_placeholder_reviewers_are_refused(tmp_path, reviewer):
    """
    A copied template that was never filled in is the likeliest route to an unreviewed
    structure reaching a render, precisely because it looks complete. The layout would be
    geometrically perfect and chemically unchecked, and nothing downstream measures chemistry.
    """
    path = write(tmp_path, reviewed_by=reviewer)
    with pytest.raises(M.StructureError) as exc:
        M.load_structure(path)
    assert "placeholder" in str(exc.value).lower()


def test_the_shipped_example_refuses_to_render(tmp_path):
    """
    `molecules/water.json` demonstrates the format, so it must not be drawable as it ships —
    otherwise the first person to try the solver renders an unreviewed molecule.
    """
    path = C.ROOT / "molecules" / "water.json"
    assert path.exists()
    with pytest.raises(M.StructureError):
        M.load_structure(path)
    assert M.main([str(path)]) != 0


# --------------------------------------------------------------------------------------
# Geometry — safe to compute, so it had better be right
# --------------------------------------------------------------------------------------

def bond_angle(layout, centre, a, b):
    pos = {x.id: (x.x, x.y) for x in layout.atoms}
    (cx, cy), (ax, ay), (bx, by) = pos[centre], pos[a], pos[b]
    v1 = math.atan2(ay - cy, ax - cx)
    v2 = math.atan2(by - cy, bx - cx)
    deg = abs(math.degrees(v1 - v2)) % 360
    return min(deg, 360 - deg)


@pytest.mark.parametrize("geometry,ideal", [
    ("tetrahedral", 109.5), ("trigonal", 120.0), ("linear", 180.0),
])
def test_acyclic_bond_angles_match_the_stated_geometry(tmp_path, geometry, ideal):
    """
    "Correct bond angles (109.5° tetrahedral, 120° trigonal) — this is a chemistry video and
    wrong angles are a factual error."
    """
    path = write(tmp_path, atoms=[
        {"id": "A", "element": "C", "geometry": geometry},
        {"id": "B", "element": "C", "geometry": geometry},
        {"id": "D", "element": "C", "geometry": geometry},
    ], bonds=[{"a": "B", "b": "A"}, {"a": "B", "b": "D"}])
    layout = M.solve(M.load_structure(path))
    # Tolerance covers the ±6 px §2.3 jitter, which is applied after the angle is set.
    assert bond_angle(layout, "B", "A", "D") == pytest.approx(ideal, abs=6.0)


def test_rings_close(tmp_path):
    """
    A ring that does not close is not a depiction of anything. Checked as a geometric fact:
    every consecutive pair around the ring is the same distance apart, including the last-to-
    first pair that actually does the closing.
    """
    for n in (5, 6):
        layout = M.solve(M.load_structure(ring(tmp_path, n)))
        pos = {a.id: (a.x, a.y) for a in layout.atoms}
        lengths = [math.dist(pos[f"C{i}"], pos[f"C{(i + 1) % n}"]) for i in range(n)]
        assert max(lengths) - min(lengths) < 0.25 * max(lengths), (
            f"{n}-ring bond lengths vary too much to be closed: {lengths}"
        )


def test_ring_is_detected(tmp_path):
    assert len(M.find_rings(M.load_structure(ring(tmp_path, 6)))) == 1
    assert M.find_rings(M.load_structure(write(tmp_path))) == []


def test_ring_forced_angle_deviation_is_reported_not_hidden(tmp_path):
    """
    A six-ring of tetrahedral carbons is drawn as a hexagon at 120°, because a planar polygon
    cannot hold 109.5° and still close. That is the standard depiction rather than an error —
    but it is a real difference between the drawing and the molecule, so it gets said out loud.
    """
    layout = M.solve(M.load_structure(ring(tmp_path, 6, geometry="tetrahedral")))
    assert layout.notes, "the hexagon/109.5° discrepancy was not reported"
    assert any("109.5" in n and "ring closure" in n for n in layout.notes)


def test_unrecorded_depiction_notes_stop_the_layout(tmp_path):
    """
    `reviewed_by` means a human looked. The angle report has to be part of what they looked at,
    not only in a log — so a structure whose deviations were never written down is not one
    that has actually been reviewed.

    This covers the case where the hexagon genuinely misleads: if the diagram is teaching chair
    conformations or bond angles, a flat 120° ring is the subject rather than a convention, and
    she is the only one who can judge that.
    """
    atoms = [{"id": f"C{i}", "element": "C", "geometry": "tetrahedral"} for i in range(6)]
    bonds = [{"a": f"C{i}", "b": f"C{(i + 1) % 6}"} for i in range(6)]
    path = write(tmp_path, "unrecorded.json", atoms=atoms, bonds=bonds)

    with pytest.raises(M.StructureError) as exc:
        M.solve(M.load_structure(path))
    assert "depiction notes" in str(exc.value)
    assert "109.5" in str(exc.value), "the notes to record must be shown, not just demanded"


def test_stale_depiction_notes_stop_the_layout(tmp_path):
    """
    Notes that no longer match mean the structure changed after she signed. Trusting the stale
    text would be worse than having none: it looks reviewed.
    """
    path = ring(tmp_path, 6)
    data = json.loads(path.read_text())
    data["depiction_notes"] = ["C0 (C) drawn at 999.9° — stale"]
    path.write_text(json.dumps(data))

    with pytest.raises(M.StructureError) as exc:
        M.solve(M.load_structure(path))
    assert "do not match" in str(exc.value)


def test_a_structure_with_no_deviations_needs_no_notes(tmp_path):
    """
    Benzene deviates from nothing, so demanding an empty list would be ceremony. The check
    only bites where there is something for her to see.
    """
    atoms = [{"id": f"C{i}", "element": "C", "geometry": "trigonal"} for i in range(6)]
    bonds = [{"a": f"C{i}", "b": f"C{(i + 1) % 6}"} for i in range(6)]
    path = write(tmp_path, "benzene.json", atoms=atoms, bonds=bonds)
    assert M.solve(M.load_structure(path)).notes == []


def test_notes_flag_prints_a_pasteable_block(tmp_path, capsys):
    """There has to be a way to obtain the text she is being asked to record."""
    atoms = [{"id": f"C{i}", "element": "C", "geometry": "tetrahedral"} for i in range(6)]
    bonds = [{"a": f"C{i}", "b": f"C{(i + 1) % 6}"} for i in range(6)]
    path = write(tmp_path, "n.json", atoms=atoms, bonds=bonds)

    assert M.main([str(path), "--notes"]) == 0
    out = capsys.readouterr().out
    assert '"depiction_notes": [' in out
    assert "109.5" in out
    assert "teaching bond angles" in out


def test_no_note_when_the_ring_matches_the_geometry(tmp_path):
    """A trigonal six-ring — benzene — is drawn at exactly its ideal 120°, so there is nothing
    to report. A solver that warned here would be crying wolf on the commonest ring there is."""
    layout = M.solve(M.load_structure(ring(tmp_path, 6, geometry="trigonal")))
    assert not layout.notes


# --------------------------------------------------------------------------------------
# Layout constraints  (§2.1, §2.2, §2.3)
# --------------------------------------------------------------------------------------

def test_everything_lands_inside_the_safe_box(tmp_path):
    """§2.1 — nothing crosses the margins, and a 24-atom molecule is where that gets tested."""
    import stage5_composite as S5

    spec = C.ASPECTS["16:9"]
    bx, by, bw, bh = S5.content_box(spec)
    layout = M.solve(M.load_structure(ring(tmp_path, 12)))
    for atom in layout.atoms:
        assert bx <= atom.x <= bx + bw, f"{atom.id} at x={atom.x:.0f} is outside the safe box"
        assert by <= atom.y <= by + bh, f"{atom.id} at y={atom.y:.0f} is outside the safe box"


def test_positions_sit_near_the_eight_px_grid(tmp_path):
    """
    §2.2 governs spacing, §2.3 governs micro-position. So a position is snapped to the 8 px
    grid and then nudged off it by up to ±6 px — never more, or the grid has stopped doing its
    job of keeping the frame from feeling accidental.
    """
    layout = M.solve(M.load_structure(ring(tmp_path, 6)))
    for atom in layout.atoms:
        for value in (atom.x, atom.y):
            off_grid = abs(value - round(value / C.GRID_UNIT) * C.GRID_UNIT)
            assert off_grid <= C.POSITION_JITTER_MAX_PX + C.GRID_UNIT / 2 + 1e-6


def test_rotations_respect_the_imperfection_budget(tmp_path):
    """§2.3 — never exactly 0°, never past the range, and neighbours lean opposite ways."""
    layout = M.solve(M.load_structure(ring(tmp_path, 6)))
    for atom in layout.atoms:
        assert atom.rotation != 0.0
        assert C.ROTATION_MIN_DEG <= abs(atom.rotation) <= C.ROTATION_MAX_DEG

    signs = [a.rotation > 0 for a in layout.atoms]
    assert all(x != y for x, y in zip(signs, signs[1:])), "uniform tilt reads as a filter"


def test_atoms_do_not_overlap(tmp_path):
    """Two discs in the same place is not a diagram, whatever the angles say."""
    layout = M.solve(M.load_structure(ring(tmp_path, 6)))
    pos = [(a.x, a.y) for a in layout.atoms]
    for i, p in enumerate(pos):
        for q in pos[i + 1:]:
            assert math.dist(p, q) > C.GRID_UNIT * 2


def test_bonds_carry_position_angle_and_length(tmp_path):
    """Stage 5 places a bond strip, so it needs where, how long, and at what angle."""
    layout = M.solve(M.load_structure(write(tmp_path)))
    assert len(layout.bonds) == 2
    for bond in layout.bonds:
        assert bond.length > 0
        assert -180 <= bond.angle <= 180
        assert bond.asset.startswith("cutout:bond_")


def test_atoms_carry_their_kit_material(tmp_path):
    """
    molecular_kit.md codes atoms by material and mark, not hue — the palette has no blue or
    yellow, and §4.1 forbids adding any.
    """
    layout = M.solve(M.load_structure(write(tmp_path)))
    assert {a.asset for a in layout.atoms} == {"cutout:atom_c", "cutout:atom_o"}
    carbon = next(a for a in layout.atoms if a.element == "C")
    oxygen = next(a for a in layout.atoms if a.element == "O")
    assert oxygen.scale < carbon.scale        # 0.95 against 1.00 in the kit table


def test_layout_is_deterministic(tmp_path):
    """Same structure in, byte-identical layout out — the determinism convention."""
    path = ring(tmp_path, 6)
    a = M.solve(M.load_structure(path))
    b = M.solve(M.load_structure(path))
    assert [(x.id, x.x, x.y, x.rotation) for x in a.atoms] == \
           [(x.id, x.x, x.y, x.rotation) for x in b.atoms]


def test_layout_carries_the_reviewer_through(tmp_path):
    """Provenance survives into the output, so what got drawn can be traced to who checked it."""
    layout = M.solve(M.load_structure(write(tmp_path)))
    assert layout.reviewed_by == "her"


def test_vertical_aspect_uses_its_own_safe_box(tmp_path):
    import stage5_composite as S5

    bx, by, bw, bh = S5.content_box(C.ASPECTS["9:16"])
    layout = M.solve(M.load_structure(ring(tmp_path, 6)), aspect="9:16")
    for atom in layout.atoms:
        assert bx <= atom.x <= bx + bw and by <= atom.y <= by + bh
