"""
Stage 4 — Asset resolution and build sheet.

This stage replaces what the original spec called "fetch/generate missing AI b-roll."
It does the opposite. See style_guide.md [S-001]:

    The pipeline never generates footage or imagery. When an asset is missing, this stage
    produces a build sheet and a shot list for her to make or film. A missing asset blocks
    the render; it does not get filled in.

That is not a limitation, it's the product. Generated footage is the one thing that can't be
rescued by grading or texture — it's recognizable, and one shot of it discredits the rest of
the video.

So Stage 4:
  1. Resolves every asset reference in the plan against assets/ and footage/.
  2. Validates the ones that exist (alpha, resolution, variant count for jitter).
  3. Writes a craft-table build sheet + a shot list for everything missing.

Output: build/plan/<project>.assets.json  +  build/plan/<project>.build-sheet.md
"""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass, field
from pathlib import Path

import cli
import config as C
import corrections as CR


IMAGE_EXTS = {".png", ".tif", ".tiff", ".webp"}
VIDEO_EXTS = {".mp4", ".mov", ".mkv", ".m4v"}

# asset ref syntax:  cutout:yeast_cell-budding | texture:kraft | broll:starter-bubbles
KIND_DIRS = {
    "cutout": (C.CUTOUTS, IMAGE_EXTS),
    "texture": (C.TEXTURES, IMAGE_EXTS | {".jpg", ".jpeg"}),
    "broll": (C.FOOTAGE / "broll", VIDEO_EXTS),
    "macro": (C.FOOTAGE / "macro", VIDEO_EXTS),
    "foley": (C.FOLEY, {".wav", ".aif", ".aiff", ".flac"}),
    "music": (C.MUSIC, {".wav", ".flac", ".mp3", ".m4a"}),
}

MIN_CUTOUT_LONG_EDGE = 2400     # taste_principles §1.2
MIN_TEXTURE_LONG_EDGE = 4000
MIN_VARIANTS = 4                # §1.2 — 4–6 shots per piece feed the stop-motion jitter


@dataclass
class Resolution:
    ref: str
    kind: str
    key: str
    status: str                          # ok | warn | missing
    files: list[str] = field(default_factory=list)
    variants: int = 0
    notes: list[str] = field(default_factory=list)
    used_by: list[str] = field(default_factory=list)


def parse_ref(ref: str) -> tuple[str, str]:
    if ":" in ref:
        kind, key = ref.split(":", 1)
        return kind.strip().lower(), key.strip()
    return "cutout", ref.strip()


def inspect_image(path: Path) -> dict:
    """Best-effort image inspection. Pillow is optional; absence downgrades to a warning."""
    info: dict = {}
    try:
        from PIL import Image  # type: ignore
    except ImportError:
        return {"unknown": True}
    try:
        with Image.open(path) as im:
            info["size"] = im.size
            info["mode"] = im.mode
            info["has_alpha"] = im.mode in ("RGBA", "LA") or "transparency" in im.info
    except Exception as exc:  # noqa: BLE001
        info["error"] = str(exc)
    return info


def resolve_ref(ref: str) -> Resolution:
    kind, key = parse_ref(ref)
    if kind not in KIND_DIRS:
        return Resolution(ref, kind, key, "missing", notes=[f"unknown asset kind '{kind}'"])

    directory, exts = KIND_DIRS[kind]
    res = Resolution(ref, kind, key, "missing")
    if not directory.is_dir():
        res.notes.append(f"{C.path_label(directory)}/ does not exist")
        return res

    # Variants share a stem prefix: yeast_cell-budding_v01_a.png, ..._b.png
    hits = sorted(
        p for p in directory.rglob("*")
        if p.is_file() and p.suffix.lower() in exts and p.stem.startswith(key)
    )
    if not hits:
        return res

    res.files = [str(C.path_label(p)) for p in hits]
    res.variants = len(hits)
    res.status = "ok"

    if kind == "cutout":
        if res.variants < MIN_VARIANTS:
            res.status = "warn"
            res.notes.append(
                f"only {res.variants} variant(s); shoot {MIN_VARIANTS}–6 with a millimetre of "
                f"movement between frames so the stop-motion jitter is real (§1.2)"
            )
        for p in hits:
            info = inspect_image(p)
            if info.get("unknown"):
                res.notes.append("Pillow not installed — could not verify alpha or resolution")
                break
            if info.get("error"):
                res.status = "warn"
                res.notes.append(f"{p.name}: unreadable ({info['error']})")
                continue
            if not info.get("has_alpha"):
                res.status = "warn"
                res.notes.append(f"{p.name}: no alpha channel — cutouts must be matted PNGs (§1.3)")
            w, h = info.get("size", (0, 0))
            if max(w, h) < MIN_CUTOUT_LONG_EDGE:
                res.status = "warn"
                res.notes.append(
                    f"{p.name}: {w}×{h} — long edge under {MIN_CUTOUT_LONG_EDGE}px, "
                    f"the edit can't push in on it (§1.2)"
                )

    elif kind == "texture":
        for p in hits:
            info = inspect_image(p)
            w, h = info.get("size", (0, 0))
            if w and max(w, h) < MIN_TEXTURE_LONG_EDGE:
                res.status = "warn"
                res.notes.append(f"{p.name}: {w}×{h} — surfaces want ≥{MIN_TEXTURE_LONG_EDGE}px")

    return res


# --------------------------------------------------------------------------------------
# Build sheet
# --------------------------------------------------------------------------------------

BUILD_HINTS = {
    "cutout": (
        "Cut from cardboard / draw on paper. Shoot overhead, flat-lit, on mid-grey seamless, "
        "raised ~10mm on foam tape. Grey card in frame 1. 4–6 variants, nudged a millimetre "
        "between each. ≥2400px long edge. Matte to PNG with a 1–2px feather — keep the fibre."
    ),
    "texture": (
        "Flat-scan or shoot the surface evenly lit, ≥4000px long edge. No shadows, no props. "
        "This becomes a background, so it needs to be clean and continuous."
    ),
    "broll": "Shoot real. Handheld or locked, graded with the channel LUT. Cover the action wide + tight.",
    "macro": "Macro insert. Shoot long — 20s+ per setup. Focus is critical; use focus peaking.",
    "foley": "Record at the table: cardboard tap, paper slide, marker squeak. 48k/24-bit, close mic.",
    "music": "Acoustic only — upright bass, brushed drums, felt piano. No synth pads, no lofi.",
}


def write_build_sheet(project: str, results: list[Resolution], path: Path) -> Path:
    missing = [r for r in results if r.status == "missing"]
    warned = [r for r in results if r.status == "warn"]
    ok = [r for r in results if r.status == "ok"]

    lines = [
        f"# Build sheet — {project}",
        "",
        f"**{len(missing)} to make · {len(warned)} needing attention · {len(ok)} ready**",
        "",
        "> The pipeline does not generate imagery or footage. Everything below gets made or shot.",
        "> See `style_guide.md` [S-001].",
        "",
    ]

    if missing:
        lines += ["---", "", "## To make", ""]
        by_kind: dict[str, list[Resolution]] = {}
        for r in missing:
            by_kind.setdefault(r.kind, []).append(r)
        for kind, items in sorted(by_kind.items()):
            lines += [f"### {kind.title()}s", "", f"*{BUILD_HINTS.get(kind, '')}*", ""]
            for r in items:
                used = ", ".join(r.used_by) or "—"
                lines.append(f"- [ ] **`{r.key}`** — cues: {used}")
                for n in r.notes:
                    lines.append(f"      - {n}")
            lines.append("")
            lines.append(f"  Save to: `{C.path_label(KIND_DIRS[kind][0])}/"
                         f"<key>_v01_a.png` (then `_b`, `_c`, …)")
            lines.append("")

    if warned:
        lines += ["---", "", "## Needs attention", ""]
        for r in warned:
            lines.append(f"- **`{r.key}`** ({r.variants} file(s))")
            for n in r.notes:
                lines.append(f"  - {n}")
        lines.append("")

    if ok:
        lines += ["---", "", "## Ready", ""]
        for r in ok:
            lines.append(f"- `{r.key}` — {r.variants} variant(s)")
        lines.append("")

    lines += [
        "---",
        "",
        "## Capture reminders (taste_principles §1.2)",
        "",
        "- Grey card + colour checker in the first frame of **every** session. This is what keeps",
        "  kraft looking like the same kraft across months of shooting.",
        "- Never shoot a piece square to frame — 1–3° off, always.",
        "- Shoot RAW. White-balance the session to the card before anything else.",
        "- Shoot the **failures** before the successes: the dead starter, the dense loaf, the",
        "  collapse. They're much harder to reproduce on demand than the good version.",
        "",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines))
    return path


def main(argv: list[str] | None = None) -> int:
    cli.preflight()
    ap = argparse.ArgumentParser(description="Stage 4 — resolve assets, write the build sheet")
    ap.add_argument("plan", nargs="?", help="build/plan/<project>.plan.json")
    ap.add_argument("--allow-missing", action="store_true",
                    help="report gaps but don't fail the run (Stage 5 will still refuse)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    # An ACTIVE correction still carrying placeholder text is a rule that
    # constrains nothing while looking like it does — style_guide [S-016]. Checked
    # before any work, so it stops the run at the top rather than after a render.
    CR.gate()

    plan_path = cli.resolve_or_exit(args.plan, expect=(".json",), label="plan") \
        if args.plan else next(iter(sorted(C.PLAN_DIR.glob("*.plan.json"))), None)
    if not plan_path or not plan_path.exists():
        print("! no plan found — run stage 3 first")
        return 1

    plan = json.loads(plan_path.read_text())
    project = plan.get("project", plan_path.stem)

    # Collect refs, remembering which cues want them.
    wanted: dict[str, list[str]] = {}
    for cue in plan.get("cues", []):
        for ref in cue.get("assets", []):
            wanted.setdefault(ref, []).append(cue["id"])

    # Every project needs a paper-grain overlay and at least one surface (§4.3).
    for implicit in ("texture:paper-grain", "texture:kraft"):
        wanted.setdefault(implicit, []).append("(required by §4.3 grain/surface pass)")

    if not wanted:
        print("! plan references no assets — nothing to resolve")
        return 0

    print(f"Stage 4 — resolving {len(wanted)} asset reference(s) for {project}")
    results: list[Resolution] = []
    for ref, used_by in sorted(wanted.items()):
        r = resolve_ref(ref)
        r.used_by = used_by
        results.append(r)
        icon = {"ok": "✓", "warn": "!", "missing": "✗"}[r.status]
        detail = f"{r.variants} variant(s)" if r.variants else "not found"
        print(f"  {icon} {ref:<40} {detail}")
        for n in r.notes:
            print(f"      {n}")

    missing = [r for r in results if r.status == "missing"]

    if args.dry_run:
        return 0

    out_json = C.PLAN_DIR / f"{project}.assets.json"
    out_json.write_text(json.dumps(
        {
            "project": project,
            "generative_assets_allowed": C.ALLOW_GENERATIVE_ASSETS,
            "ready": len([r for r in results if r.status == "ok"]),
            "warn": len([r for r in results if r.status == "warn"]),
            "missing": len(missing),
            "resolutions": [asdict(r) for r in results],
        },
        indent=2,
    ))
    sheet = write_build_sheet(project, results, C.PLAN_DIR / f"{project}.build-sheet.md")

    print(f"\n  → {C.path_label(out_json)}")
    print(f"  → {C.path_label(sheet)}")

    if missing:
        print(f"\n! {len(missing)} asset(s) missing. The pipeline does not generate them.")
        print(f"  Work through {C.path_label(sheet)}, then re-run Stage 4.")
        return 0 if args.allow_missing else 3

    print("\nStage 4 complete — all assets resolved")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
