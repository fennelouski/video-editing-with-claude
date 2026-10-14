"""
Stage 6 — The Watch agent.

Reviews an export that comes back **out of Final Cut**. The pipeline hands FCP a timeline at
Stage 5; she cuts, grades, and exports; this stage then scores what she actually made rather
than what the pipeline proposed.

Drop the FCP export into `build/exports/` (any .mp4/.mov) and run. Because it reviews the
graded export, the colour and loudness checks are meaningful here in a way they wouldn't be
against an ungraded assembly.

Extracts frames from the export and scores them against the taste_principles §12 rubric.
Anything that fails gets written back to style_guide.md as a correction entry, which the
earlier stages read on the next run. That loop is the whole point: the same mistake never
gets made twice.

What it will NOT do (config.ESCALATE_TO_HUMAN): touch a scientific claim, a number, a chart,
or a person's name. Those are escalated. She's a food scientist — the pipeline does not get
a vote on the chemistry.

Output: build/review/<project>.review.json  ·  build/review/<project>.review.md
"""

from __future__ import annotations

import argparse
import json
import math
import re
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from datetime import date
from pathlib import Path

import cli
import config as C

try:
    import numpy as np
    from PIL import Image
except ImportError:  # pragma: no cover
    np = None  # type: ignore
    Image = None  # type: ignore


@dataclass
class Finding:
    check: int
    name: str
    severity: str            # fail | warn | info
    frame: str
    detail: str
    category: str
    auto_check: bool = True
    escalate: bool = False


@dataclass
class Report:
    project: str
    frames_examined: int = 0
    findings: list[Finding] = field(default_factory=list)

    @property
    def fails(self) -> list[Finding]:
        return [f for f in self.findings if f.severity == "fail"]

    @property
    def warns(self) -> list[Finding]:
        return [f for f in self.findings if f.severity == "warn"]


# --------------------------------------------------------------------------------------
# Colour science
# --------------------------------------------------------------------------------------

def srgb_to_lab(rgb: "np.ndarray") -> "np.ndarray":
    """sRGB (0–255) → CIE Lab (D65). Vectorised over the trailing axis."""
    c = rgb.astype(np.float64) / 255.0
    c = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    m = np.array([[0.4124, 0.3576, 0.1805],
                  [0.2126, 0.7152, 0.0722],
                  [0.0193, 0.1192, 0.9505]])
    xyz = c @ m.T
    white = np.array([0.95047, 1.0, 1.08883])
    xyz = xyz / white
    eps, kappa = 216 / 24389, 24389 / 27
    f = np.where(xyz > eps, np.cbrt(xyz), (kappa * xyz + 16) / 116)
    return np.stack([116 * f[..., 1] - 16,
                     500 * (f[..., 0] - f[..., 1]),
                     200 * (f[..., 1] - f[..., 2])], axis=-1)


def delta_e(a: "np.ndarray", b: "np.ndarray") -> "np.ndarray":
    """CIE76. Good enough for palette-drift detection at ΔE 6."""
    return np.sqrt(((a - b) ** 2).sum(axis=-1))


def relative_luminance(rgb: "np.ndarray") -> "np.ndarray":
    c = rgb.astype(np.float64) / 255.0
    c = np.where(c <= 0.03928, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    return 0.2126 * c[..., 0] + 0.7152 * c[..., 1] + 0.0722 * c[..., 2]


def contrast_ratio(l1: float, l2: float) -> float:
    hi, lo = max(l1, l2), min(l1, l2)
    return (hi + 0.05) / (lo + 0.05)


# --------------------------------------------------------------------------------------
# Frame extraction
# --------------------------------------------------------------------------------------

def extract_frames(video: Path, out_dir: Path, every: float = 2.0) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob("*.png"):
        old.unlink()
    cmd = ["ffmpeg", "-y", "-i", str(video), "-vf", f"fps=1/{every}", str(out_dir / "f%05d.png")]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"frame extraction failed:\n{proc.stderr[-600:]}")
    return sorted(out_dir.glob("*.png"))


def measure_loudness(video: Path) -> dict:
    """ffmpeg's ebur128 pass — §12 check 17."""
    cmd = ["ffmpeg", "-nostats", "-i", str(video), "-filter_complex", "ebur128=peak=true",
           "-f", "null", "-"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    tail = proc.stderr[-2500:]
    out: dict = {}
    for key, pattern in (
        ("lufs", r"I:\s*(-?\d+\.?\d*)\s*LUFS"),
        ("lra", r"LRA:\s*(-?\d+\.?\d*)\s*LU"),
        ("peak", r"Peak:\s*(-?\d+\.?\d*)\s*dBFS"),
    ):
        m = re.findall(pattern, tail)
        if m:
            out[key] = float(m[-1])
    return out


# --------------------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------------------

def check_frame(path: Path, aspect: str, report: Report, resolution: str | None = None) -> None:
    spec = C.canvas_spec(aspect, resolution)
    with Image.open(path) as im:
        im = im.convert("RGB")
        if im.size != tuple(spec["author"]):
            im = im.resize(spec["author"], Image.LANCZOS)
        arr = np.asarray(im)

    h, w, _ = arr.shape
    name = path.name

    # --- check 9: pure black / pure white in the graphic layer -------------------------
    pure_white = float((arr == 255).all(axis=-1).mean())
    pure_black = float((arr == 0).all(axis=-1).mean())
    if pure_white > C.CLIP_WHITE_FAIL_THRESHOLD:
        report.findings.append(Finding(
            9, "pure values", "fail", name, category="color",
            detail=(f"{pure_white:.2%} of the frame is #FFFFFF. Highlights roll off at "
                    f"{C.HIGHLIGHT_ROLLOFF_IRE[0]}–{C.HIGHLIGHT_ROLLOFF_IRE[1]} IRE — a clipped "
                    f"white is the most rendered-looking thing in a warm frame (§4.1, §7)."),
        ))
    if pure_black > C.CLIP_WHITE_FAIL_THRESHOLD:
        report.findings.append(Finding(
            9, "pure values", "fail", name, category="color",
            detail=(f"{pure_black:.2%} of the frame is #000000. Blacks lift to "
                    f"{C.BLACK_LIFT_IRE[0]}–{C.BLACK_LIFT_IRE[1]} IRE; shadows are walnut, "
                    f"not black (§4.1)."),
        ))

    # --- check 8: rust budget ----------------------------------------------------------
    small = arr[::4, ::4]
    lab = srgb_to_lab(small.reshape(-1, 3))
    rust_lab = srgb_to_lab(np.array([[int(C.PALETTE["rust"][i:i+2], 16) for i in (1, 3, 5)]]))
    rust_frac = float((delta_e(lab, rust_lab) < 18).mean())
    if rust_frac > C.ACCENT_MAX_FRAME_FRACTION:
        report.findings.append(Finding(
            8, "rust budget", "fail", name, category="color",
            detail=(f"accent covers {rust_frac:.1%} of the frame (max "
                    f"{C.ACCENT_MAX_FRAME_FRACTION:.0%}). Rust is a scalpel — past a tenth "
                    f"of the frame nothing is emphasised (§4.2)."),
        ))

    # --- check 7: palette drift --------------------------------------------------------
    # Sample the frame's dominant graphic colours and compare to the token set. Skip frames
    # that are mostly photographic — real food is graded, never palette-forced (§4.1).
    tokens = np.array([[int(v[i:i+2], 16) for i in (1, 3, 5)] for v in C.PALETTE.values()])
    token_lab = srgb_to_lab(tokens)
    d = np.stack([delta_e(lab, token_lab[i:i+1]) for i in range(len(token_lab))], axis=-1)
    nearest = d.min(axis=-1)
    drift = float((nearest > C.PALETTE_DELTA_E_MAX).mean())
    if drift > 0.55:
        report.findings.append(Finding(
            7, "palette drift", "warn", name, category="color",
            detail=(f"{drift:.0%} of sampled pixels sit >ΔE{C.PALETTE_DELTA_E_MAX:.0f} from the "
                    f"Sage & Oat tokens. Expected on photographic frames; a problem on graphics."),
        ))

    # --- check 1 & 20: safe zone occupancy ---------------------------------------------
    # High-frequency content (text, hard cut edges) outside the margin box is a violation.
    grey = np.asarray(Image.fromarray(arr).convert("L"), dtype=np.float64)
    gx = np.abs(np.diff(grey, axis=1, prepend=grey[:, :1]))
    gy = np.abs(np.diff(grey, axis=0, prepend=grey[:1, :]))
    edges = (gx + gy) > 60

    bands = {
        "left": edges[:, : spec["margin_left"]],
        "right": edges[:, w - spec["margin_right"]:],
        "top": edges[: spec["margin_top"], :],
        "bottom": edges[h - spec["margin_bottom"]:, :],
    }
    for band, region in bands.items():
        density = float(region.mean())
        if density > 0.045:
            report.findings.append(Finding(
                1, "safe zone", "warn", name, category="layout",
                detail=(f"busy content in the {band} margin ({density:.1%} edge density). "
                        f"Nothing crosses the outer margin (§2.1). If this is footage rather "
                        f"than a graphic, reframe at shoot time."),
            ))

    # 9:16 player-chrome band is stricter — it's covered by UI, not just tight.
    if aspect == "9:16":
        chrome = edges[h - spec["chrome_bottom"]:, :]
        if float(chrome.mean()) > 0.03:
            report.findings.append(Finding(
                20, "platform UI collision", "fail", name, category="layout",
                detail=("content in the bottom 480px, which the caption, handle, audio ticker "
                        "and CTA sit on top of. Move it into the hero band, y=480–1300 (§2.1)."),
            ))

    # --- check 2: caption contrast -----------------------------------------------------
    # Only meaningful when a caption is actually on screen. An empty band is not a failure,
    # and flagging it would bury the real findings.
    cap_top = max(0, spec["caption_baseline"] - 120)
    cap = arr[cap_top: spec["caption_baseline"], spec["margin_left"]: w - spec["margin_right"]]
    cap_edges = edges[cap_top: spec["caption_baseline"], spec["margin_left"]: w - spec["margin_right"]]
    has_caption = cap_edges.size > 0 and float(cap_edges.mean()) > 0.012
    if cap.size and has_caption:
        lum = relative_luminance(cap)
        ratio = contrast_ratio(float(lum.max()), float(lum.min()))
        if ratio < 4.5:
            report.findings.append(Finding(
                2, "contrast", "fail", name, category="typography",
                detail=(f"caption band contrast {ratio:.1f}:1, needs ≥4.5:1 against the "
                        f"brightest pixel behind it. Add the torn-paper strip or the ink "
                        f"plate (§6.7)."),
            ))


def check_motion(frames: list[Path], report: Report) -> None:
    """
    §12 check 6 — idle jitter. A graphic element with zero frame-to-frame delta for more
    than STATIC_FRAMES_FAIL frames is a bug: real stop-motion is never perfectly still.
    """
    if len(frames) < 2:
        return
    static_run = 0
    for a, b in zip(frames, frames[1:]):
        with Image.open(a) as ia, Image.open(b) as ib:
            aa = np.asarray(ia.convert("L").resize((320, 180)), dtype=np.int16)
            bb = np.asarray(ib.convert("L").resize((320, 180)), dtype=np.int16)
        if float(np.abs(aa - bb).mean()) < 0.35:
            static_run += 1
            if static_run == 2:
                report.findings.append(Finding(
                    6, "idle jitter", "warn", b.name, category="motion",
                    detail=("consecutive sampled frames are effectively identical. Every graphic "
                            "element carries ±1.5px / ±0.4° micro-jitter on the step clock — "
                            "a perfectly static graphic is a bug (§5.2)."),
                ))
        else:
            static_run = 0


def check_audio(video: Path, report: Report) -> None:
    m = measure_loudness(video)
    if not m:
        report.findings.append(Finding(
            17, "loudness", "info", video.name, category="audio",
            detail="could not measure loudness — is there an audio track?", auto_check=False))
        return
    lufs = m.get("lufs")
    if lufs is not None and abs(lufs - C.TARGET_LUFS) > C.LUFS_TOLERANCE:
        report.findings.append(Finding(
            17, "loudness", "fail", video.name, category="audio",
            detail=(f"programme is {lufs:.1f} LUFS, target {C.TARGET_LUFS:.0f} "
                    f"±{C.LUFS_TOLERANCE:.0f} (§8)."),
        ))
    peak = m.get("peak")
    if peak is not None and peak > C.TRUE_PEAK_MAX_DBTP:
        report.findings.append(Finding(
            17, "true peak", "fail", video.name, category="audio",
            detail=f"true peak {peak:.1f} dBFS, max {C.TRUE_PEAK_MAX_DBTP} dBTP (§8).",
        ))


def check_plan_pacing(report: Report, project: str) -> None:
    """§12 check 18 — pattern interrupt at least every 45s (§9)."""
    plan_path = C.PLAN_DIR / f"{project}.plan.json"
    if not plan_path.exists():
        return
    plan = json.loads(plan_path.read_text())
    beats = sorted(c["start"] for c in plan.get("cues", [])
                   if c.get("start") is not None
                   and c["kind"] in {"GFX", "BROLL", "MACRO", "CAM", "CHAPTER"})
    prev = 0.0
    for b in beats:
        if b - prev > C.PATTERN_INTERRUPT_MAX_SECONDS:
            report.findings.append(Finding(
                18, "pattern interrupt", "warn", f"{prev:.0f}s–{b:.0f}s", category="pacing",
                detail=(f"{b - prev:.0f}s with no camera change, graphic, or b-roll cut. "
                        f"Max {C.PATTERN_INTERRUPT_MAX_SECONDS}s (§9)."),
            ))
        prev = b


def check_breath(report: Report) -> None:
    """§12 check 16 — no trimmed silence below the breath floor."""
    for edl_path in sorted(C.ROUGHCUT.glob("*.edl.json")):
        edl = json.loads(edl_path.read_text())
        keeps = edl.get("keeps", [])
        for a, b in zip(keeps, keeps[1:]):
            gap_ms = (b["start"] - a["end"]) * 1000
            if 0 < gap_ms < C.BREATH_FLOOR_MS:
                report.findings.append(Finding(
                    16, "breath floor", "fail", edl_path.name, category="audio",
                    detail=(f"a {gap_ms:.0f}ms gap survived at {a['end']:.2f}s — floor is "
                            f"{C.BREATH_FLOOR_MS}ms. Cutting pauses to zero is the machine-edit "
                            f"tell (style_guide [S-002])."),
                ))


# --------------------------------------------------------------------------------------
# Reporting + the learning loop
# --------------------------------------------------------------------------------------

def write_markdown(report: Report, path: Path) -> Path:
    lines = [
        f"# Review — {report.project}",
        "",
        f"{len(report.fails)} fail · {len(report.warns)} warn · "
        f"{report.frames_examined} frames examined",
        "",
    ]
    if not report.findings:
        lines += ["Clean pass. Nothing to send back.", ""]
    for severity, title in (("fail", "Fails"), ("warn", "Warnings"), ("info", "Notes")):
        items = [f for f in report.findings if f.severity == severity]
        if not items:
            continue
        lines += [f"## {title}", ""]
        grouped: dict[tuple[int, str], list[Finding]] = {}
        for f in items:
            grouped.setdefault((f.check, f.category), []).append(f)
        for (check, category), group in sorted(grouped.items()):
            frames = [g.frame for g in group]
            where = frames[0] if len(frames) == 1 else f"{len(frames)} frames, {frames[0]} … {frames[-1]}"
            lines.append(f"- **[{check}] {group[0].name}** · `{where}` · _{category}_")
            lines.append(f"  {group[0].detail}")
        lines.append("")

    lines += [
        "---",
        "",
        "## Escalated — not auto-fixable",
        "",
        "The pipeline never adjudicates these. They go to her:",
        "",
        "- any scientific claim, temperature, timing, or mechanism",
        "- any number or chart value",
        "- any person's name or credential",
        "- anything that has failed the same check twice",
        "",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines))
    return path


def append_to_style_guide(report: Report) -> int:
    """
    The learning loop: every fail becomes an entry in style_guide.md, which stages 3–5 read
    on the next run. Entries are appended under the marker, newest first.
    """
    if not report.fails:
        return 0
    sg = C.correction_log_path(create=True)
    if not sg.exists():
        return 0
    text = sg.read_text()
    marker = "<!-- NEW ENTRIES GO DIRECTLY BELOW THIS LINE -->"
    if marker not in text:
        return 0

    existing = len(re.findall(r"^### \[A-\d+\]", text, re.M))

    # One entry per distinct defect, not per frame. A single bad graphic can fail the same
    # check on eighty frames; eighty near-identical entries would bury the log and make the
    # promotion rule meaningless.
    grouped: dict[tuple[int, str], list[Finding]] = {}
    for f in report.fails:
        grouped.setdefault((f.check, f.category), []).append(f)

    blocks = []
    for i, ((check, category), items) in enumerate(sorted(grouped.items()), start=existing + 1):
        frames = [f.frame for f in items]
        where = frames[0] if len(frames) == 1 else f"{len(frames)} frames ({frames[0]} … {frames[-1]})"
        blocks.append(
            f"\n### [A-{i:03d}] — {items[0].name} (check {check})\n"
            f"- **Date:** {date.today().isoformat()}\n"
            f"- **Video / shot:** {report.project} · {where}\n"
            f"- **Source:** stage6-auto\n"
            f"- **Status:** ACTIVE\n"
            f"- **Category:** {category}\n"
            f"- **What was wrong:** {items[0].detail}\n"
            f"- **Why it was wrong:** violates taste_principles §12 check {check}.\n"
            f"- **The rule going forward:** _write this as a testable rule before the next run._\n"
            f"- **Auto-check:** Stage 6 check {check}\n"
        )
    if not blocks:
        return 0
    sg.write_text(text.replace(marker, marker + "\n" + "\n".join(blocks)))
    return len(blocks)


def find_export() -> Path | None:
    """Newest video in build/exports/ — whatever she last exported out of Final Cut."""
    candidates = [p for p in C.EXPORTS.iterdir()
                  if p.is_file() and p.suffix.lower() in {".mp4", ".mov", ".m4v"}]
    return max(candidates, key=lambda p: p.stat().st_mtime) if candidates else None


def main(argv: list[str] | None = None) -> int:
    cli.preflight(('numpy', 'PIL'))
    ap = argparse.ArgumentParser(description="Stage 6 — the Watch agent")
    ap.add_argument("video", nargs="?", help="FCP export to review (default: newest in build/exports)")
    ap.add_argument("--project", default=None)
    ap.add_argument("--aspect", default=C.DEFAULT_ASPECT, choices=list(C.ASPECTS))
    ap.add_argument("--resolution", default=C.DEFAULT_RESOLUTION, choices=list(C.RESOLUTIONS))
    ap.add_argument("--every", type=float, default=2.0, help="seconds between sampled frames")
    ap.add_argument("--no-log", action="store_true", help="don't append fails to style_guide.md")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    if np is None or Image is None:
        print("! Stage 6 needs numpy and pillow:  pip install numpy pillow", file=sys.stderr)
        return 2

    video = cli.resolve_or_exit(args.video, expect=(".mov", ".mp4", ".m4v", ".avi", ".mts", ".mxf"), label="export") \
        if args.video else find_export()
    if not video or not video.exists():
        print("! no export found in build/exports/")
        print("  Stage 5 hands Final Cut a timeline; export from FCP into build/exports/")
        print("  and run this stage against it.")
        return 1

    project = args.project or re.sub(r"\.(master|export|final)$", "", video.stem)
    report = Report(project=project)
    print(f"Stage 6 — reviewing {video.name}")

    if args.dry_run:
        print(f"  would sample every {args.every}s and run 20 checks")
        return 0

    frames = extract_frames(video, C.REVIEW / project / "frames", args.every)
    report.frames_examined = len(frames)
    print(f"  {len(frames)} frames extracted")

    for i, f in enumerate(frames):
        check_frame(f, args.aspect, report, resolution=args.resolution)
        if (i + 1) % 25 == 0:
            print(f"    …{i + 1}/{len(frames)}")

    check_motion(frames, report)
    check_audio(video, report)
    check_plan_pacing(report, project)
    check_breath(report)

    out_json = C.REVIEW / f"{project}.review.json"
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(
        {"project": project, "video": video.name, "frames": report.frames_examined,
         "fails": len(report.fails), "warns": len(report.warns),
         "findings": [asdict(f) for f in report.findings]},
        indent=2))
    md = write_markdown(report, C.REVIEW / f"{project}.review.md")

    print(f"\n  {len(report.fails)} fail · {len(report.warns)} warn")
    for f in report.fails[:12]:
        print(f"    ✗ [{f.check}] {f.name} · {f.frame}")
        print(f"        {f.detail[:110]}")
    if len(report.fails) > 12:
        print(f"    … and {len(report.fails) - 12} more")

    print(f"\n  → {C.path_label(md)}")
    if not args.no_log:
        n = append_to_style_guide(report)
        if n:
            print(f"  → {n} entry/entries appended to style_guide.md")
            print("    Write the 'rule going forward' line on each before the next run —")
            print("    an entry without a testable rule teaches the pipeline nothing.")

    return 1 if report.fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
