"""
segment_sheet.py — one photo of several cardboard pieces → individual matted PNGs.

    python scripts/tools/segment_sheet.py sheets/session01_a.jpg \
        --keys yeast_cell-budding,thermometer,flour_sack --variant a

Input is what §1.2 specifies: pieces on a neutral mid-grey seamless, raised ~10 mm on foam
tape, shot from directly overhead with a grey card in the frame. Output is
`assets/cutouts/<key>_v<NN>_<variant>.png`, straight-alpha, ready for Stage 5.

What this tool deliberately does *not* do (all §1.3, "store the unmodified extraction"):

  - It does not deskew, straighten or re-square anything. §1.2 has her shoot every piece 1–3°
    off-square on purpose. Correcting that would be destroying the work, not cleaning it up.
  - It does not scale, sharpen or denoise. All of that happens in comp.
  - It does not trace the matte into a path. Cut and torn edges keep their irregularity, and
    the matte is feathered 1–2 px because a 0 px matte gives the vector-crisp edge that is
    the single most recognisable AI tell.

The one place it does change colour, stated plainly because "unmodified extraction" is a
strong claim: `sheet.edge_extend` rewrites a thin ring at the matte boundary and the
transparent side beyond it. The matte is derived from colour distance, so its edge lands where
the capture is roughly half cardboard and half seamless — a lens renders a cut edge over
several pixels. Left alone, those pixels sit at full alpha carrying a grey blend, which is a
visible grey rim on whatever the piece is later composited over. Shrinking the matte instead
would eat fibre and break §1.3, so the matte stays generous and the colour is corrected. The
artwork's interior is pixel-for-pixel the capture, and alpha is never touched.

A piece under the §1.2 resolution floor is reported and skipped, never silently written —
a cutout the edit cannot push in on is not usable, and finding that out at Stage 5 is too late.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import cli
import config as C          # noqa: E402
import sheet as S           # noqa: E402


# §1.2 — every piece fills at least this on its long edge, so the edit can push in on it.
MIN_LONG_EDGE_PX = 2400

# Matte thresholds, as a fraction of the distance-from-background scale in sheet.py. The gap
# between them is what preserves fibre: `HIGH` finds the solid body of a piece, `LOW` grows
# out into the fuzz on a torn edge that is attached to it.
MATTE_HIGH = 0.14
MATTE_LOW = 0.045

# A piece smaller than this is a crumb, a foam-tape corner, or sensor dirt.
MIN_PIECE_AREA_PX = 40_000


def parse_patch(spec: str) -> tuple[slice, slice]:
    """`x,y,w,h` -> array slices."""
    try:
        x, y, w, h = (int(v) for v in spec.split(","))
    except ValueError:
        raise SystemExit(f"! --grey-card wants x,y,w,h in pixels, got {spec!r}")
    return slice(y, y + h), slice(x, x + w)


def resolve_gains(rgb: np.ndarray, grey_card: str | None,
                  gains: str | None) -> tuple[tuple[float, float, float], str]:
    """
    White-balance gains, and where they came from.

    §1.2 wants one balance applied consistently across a session, so explicit `--gains` wins:
    that is how sheet two through sheet twelve inherit sheet one's card. Failing that, the
    seamless itself is a legitimate neutral reference — the spec calls for a *neutral* mid-grey
    background, so balancing to it is balancing to a grey card that happens to fill the frame.
    """
    if gains:
        try:
            r, g, b = (float(v) for v in gains.split(","))
        except ValueError:
            raise SystemExit(f"! --gains wants three numbers r,g,b, got {gains!r}")
        return (r, g, b), "explicit --gains"
    if grey_card:
        ys, xs = parse_patch(grey_card)
        patch = rgb[ys, xs]
        if patch.size == 0:
            raise SystemExit("! --grey-card patch is outside the image")
        return S.neutral_gains(patch), "grey card patch"
    return S.neutral_gains(S.estimate_background(rgb)[None, None, :]), "the seamless background"


def sidecar_for(path: Path) -> Path:
    """`session01_a.jpg` -> `session01_a.capture.json` — the session's measured references."""
    return path.with_suffix(".capture.json")


def parse_rgb(spec, label: str) -> np.ndarray:
    """Accepts a JSON list from the sidecar or an `R,G,B` string from the command line."""
    try:
        if isinstance(spec, (list, tuple)):
            values = [float(v) for v in spec]
        else:
            values = [float(v) for v in str(spec).replace(",", " ").split()]
    except (ValueError, TypeError):
        raise SystemExit(f"! {label} wants three numbers R,G,B — got {spec!r}")
    if len(values) != 3:
        raise SystemExit(f"! {label} wants three numbers R,G,B — got {spec!r}")
    rgb = np.asarray(values, dtype=np.float32)
    return rgb / 255.0 if rgb.max() > 1.0 else rgb


def resolve_references(path: Path, seamless: str | None,
                       shadow: str | None) -> tuple[np.ndarray, np.ndarray]:
    """
    The two measured references: the seamless, and the deepest shadow in the frame.

    Both are measured, never inferred ([S-013], [S-014]). Every matting decision is made
    relative to the backdrop, and the [S-012] direction check — "colour must move *away* from
    the seamless" — is only meaningful against a reference that did not come from the same
    pixels it is being used to judge.

    The shadow reference sets the floor that keeps a dark near-neutral piece from being read as
    very deep shadow. Both come off the same grey-card frame §1.2 already requires, so this is
    a recording habit rather than extra work.
    """
    recorded: dict = {}
    sidecar = sidecar_for(path)
    if sidecar.exists():
        try:
            recorded = json.loads(sidecar.read_text())
        except json.JSONDecodeError as exc:
            raise SystemExit(f"! {sidecar.name} is not valid JSON: {exc}")

    seamless_spec = seamless if seamless is not None else recorded.get("seamless")
    shadow_spec = shadow if shadow is not None else recorded.get("deepest_shadow")

    missing = [name for name, spec in
               (("seamless", seamless_spec), ("deepest_shadow", shadow_spec)) if spec is None]
    if missing:
        raise SystemExit(
            f"! {path.name} has no measured {' or '.join(missing)} — [S-013]/[S-014] require "
            f"these measured, not inferred.\n"
            f"  Both come off the grey-card frame §1.2 already asks for: the seamless value,\n"
            f"  and the deepest shadow cast by a piece raised on foam tape. Then either:\n"
            f"    --seamless R,G,B --shadow R,G,B      (0–1 or 0–255)\n"
            f"  or record them in {sidecar.name}:\n"
            f'    {{"seamless": [0.49, 0.46, 0.41], "deepest_shadow": [0.34, 0.32, 0.29]}}\n'
            f"  Inferring the seamless would make the [S-012] direction check circular, and\n"
            f"  guessing the shadow floor would bake a lighting-dependent constant into code."
        )

    return (parse_rgb(seamless_spec, "seamless"),
            parse_rgb(shadow_spec, "deepest_shadow"))


def segment(path: Path, keys: list[str], variant: str, version: int,
            out_dir: Path, grey_card: str | None, gains_spec: str | None,
            feather_px: float, extend_px: int, seamless_spec: str | None,
            shadow_spec: str | None, dry_run: bool) -> int:
    rgb = S.load_rgb(path)
    h, w, _ = rgb.shape
    print(f"\n{path.name} — {w}x{h}")

    seamless, deepest_shadow = resolve_references(path, seamless_spec, shadow_spec)

    gains, source = resolve_gains(rgb, grey_card, gains_spec)
    print(f"  white balance from {source}: "
          f"R {gains[0]:.4f}  G {gains[1]:.4f}  B {gains[2]:.4f}")
    if source != "explicit --gains":
        print(f"    reuse across this session with:  --gains "
              f"{gains[0]:.4f},{gains[1]:.4f},{gains[2]:.4f}")
    balanced = S.apply_gains(rgb, gains)

    # The recorded values are what the camera saw, so they get the same balance the sheet does.
    background = S.apply_gains(seamless[None, None, :], gains)[0, 0]
    shadow = S.apply_gains(deepest_shadow[None, None, :], gains)[0, 0]
    floor = S.shadow_floor_from(background, shadow)

    measured = S.estimate_background(balanced)
    drift = float(np.abs(background - measured).max())
    print(f"  seamless {np.round(background, 3)} (recorded)"
          f"  · this sheet measures {np.round(measured, 3)}, drift {drift:.3f}")
    print(f"  shadow floor {floor:.3f} of backdrop — anything darker on the backdrop ray is "
          f"a piece, not shade ([S-014])")
    if drift > 0.06:
        print("  ! the sheet's backdrop is a long way from the recorded value — check the "
              "lighting has not moved, or re-measure the grey card for this session")
    if not 0.0 < floor < 1.0:
        print(f"  ! shadow floor {floor:.3f} is outside (0, 1) — the recorded shadow is not "
              f"darker than the seamless. Check which sample went in which field.")

    distance = S.background_distance(balanced, background, shadow_floor=floor)
    scale = float(distance.max()) or 1.0
    mask = S.solidify(S.hysteresis_mask(distance, MATTE_HIGH * scale, MATTE_LOW * scale))

    boxes = S.find_pieces(mask, min_area=MIN_PIECE_AREA_PX)
    if not boxes:
        print("  ! no pieces found.")
        print("    Check the seamless is evenly lit and the pieces are not the same tone as it.")
        return 1

    print(f"  {len(boxes)} piece(s) found, in reading order")
    if len(keys) < len(boxes):
        print(f"  ! only {len(keys)} key(s) given for {len(boxes)} piece(s) — the rest are "
              f"named 'unnamed-NN' and must be renamed before Stage 4 will resolve them")

    out_dir.mkdir(parents=True, exist_ok=True)
    written = skipped = 0

    for i, (ys, xs) in enumerate(boxes):
        key = keys[i] if i < len(keys) else f"unnamed-{i + 1:02d}"
        piece_h, piece_w = ys.stop - ys.start, xs.stop - xs.start
        long_edge = max(piece_h, piece_w)

        if long_edge < MIN_LONG_EDGE_PX:
            short_by = MIN_LONG_EDGE_PX - long_edge
            print(f"    ✗ {key}: {piece_w}x{piece_h} — long edge {long_edge} px is "
                  f"{short_by} px under the {MIN_LONG_EDGE_PX} px floor (§1.2), skipped")
            print(f"        Reshoot {MIN_LONG_EDGE_PX / long_edge:.2f}x closer, or put fewer "
                  f"pieces on the sheet. Below the floor the edit cannot push in on it.")
            skipped += 1
            continue

        alpha = S.feather(mask[ys, xs], feather_px)
        colour = S.edge_extend(balanced[ys, xs], alpha, radius=extend_px)

        name = f"{key}_v{version:02d}_{variant}.png"
        coverage = float((alpha > 0.5).mean())
        print(f"    ✓ {key}: {piece_w}x{piece_h}  fills {coverage:6.1%} of its box  → {name}")
        if not dry_run:
            S.save_rgba(out_dir / name, colour, alpha)
        written += 1

    verb = "would be written" if dry_run else "written"
    print(f"  {written} {verb}, {skipped} skipped")
    # A skipped piece is a reshoot, not a detail. Exiting 0 on a partial result is how a
    # missing cutout gets discovered at Stage 4 instead of while the sheet is still on the
    # table — "failures are loud and actionable".
    return 0 if written and not skipped else 1


def main(argv: list[str] | None = None) -> int:
    cli.preflight(('numpy', 'scipy', 'PIL'))
    ap = argparse.ArgumentParser(
        description="Segment a sheet of cardboard pieces into matted PNGs (§1.2, §1.3)",
    )
    ap.add_argument("sheets", nargs="+", type=Path, help="photo(s) of pieces on grey seamless")
    ap.add_argument("--keys", default="",
                    help="comma-separated subject names in reading order, e.g. "
                         "yeast_cell-budding,thermometer")
    ap.add_argument("--variant", default="a",
                    help="variant letter a–f; §1.2 wants every piece shot 4–6 times")
    ap.add_argument("--version", type=int, default=1, help="version number for <key>_vNN_")
    ap.add_argument("--out", type=Path, default=C.CUTOUTS)
    ap.add_argument("--grey-card", help="x,y,w,h of the grey card patch in the frame")
    ap.add_argument("--gains", help="r,g,b white-balance gains, to reuse one card across a session")
    ap.add_argument("--feather", type=float, default=1.5,
                    help="matte feather in px; §1.3 requires 1–2, never 0")
    ap.add_argument("--edge-extend", type=int, default=16,
                    help="px of colour bled under the matte for downstream resamplers")
    ap.add_argument("--seamless",
                    help="measured backdrop value R,G,B (0–1 or 0–255) from the session's "
                         "grey-card frame. [S-013] — required, never inferred from the sheet.")
    ap.add_argument("--shadow",
                    help="deepest shadow value R,G,B from the same frame. [S-014] — sets the "
                         "floor below which an on-ray pixel is a dark piece, not shade.")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    if not 1.0 <= args.feather <= 2.0:
        print(f"! --feather {args.feather} is outside the 1–2 px §1.3 requires.")
        print("  0 px gives the vector-crisp edge this whole system exists to avoid.")
        return 2
    if args.variant not in tuple("abcdef"):
        print(f"! --variant {args.variant!r} — §1.2 shoots 4–6 variants, lettered a–f")
        return 2

    keys = [k.strip() for k in args.keys.split(",") if k.strip()]
    worst = 0
    for raw in args.sheets:
        path = cli.resolve_or_exit(raw, expect=(".jpg", ".jpeg", ".png", ".tif", ".tiff", ".heic", ".webp"), label="sheet photo")
        worst = max(worst, segment(path, keys, args.variant, args.version, args.out,
                                   args.grey_card, args.gains, args.feather,
                                   args.edge_extend, args.seamless, args.shadow,
                                   args.dry_run))
    return worst


if __name__ == "__main__":
    raise SystemExit(main())
