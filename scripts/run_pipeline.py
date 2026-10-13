"""
run_pipeline.py — master control.

Orchestrates the six stages. Every stage is also runnable on its own; this just sequences
them, carries the failure semantics, and stops when stopping is the right answer.

    python scripts/run_pipeline.py                    # full run
    python scripts/run_pipeline.py --from 3           # resume from stage 3
    python scripts/run_pipeline.py --only 5           # one stage
    python scripts/run_pipeline.py --dry-run          # plan the run, touch nothing
    python scripts/run_pipeline.py --aspect 9:16      # vertical cut

Stage 4 is a hard gate. If an asset is missing, the run stops and hands back a build sheet —
it does not generate a substitute. See style_guide.md [S-001].
"""

from __future__ import annotations

import argparse
import importlib
import json
from contextlib import redirect_stdout
import shutil
import sys
import time
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import cli
import config as C  # noqa: E402


@dataclass
class Stage:
    number: int
    key: str
    module: str
    title: str
    blocking: bool = True       # a non-zero exit stops the run
    gate_message: str = ""


STAGES = [
    Stage(1, "transcribe", "stage1_transcribe", "Transcribe (WhisperX, word-level)"),
    Stage(2, "roughcut", "stage2_roughcut", "Rough cut (breath floor, retakes, dead air)"),
    Stage(3, "plan", "stage3_plan", "Graphic plan (parse the annotated script)"),
    Stage(4, "assets", "stage4_assets", "Resolve assets / build sheet",
          gate_message=("Missing assets are not generated. Work through the build sheet, "
                        "then re-run from stage 4.")),
    Stage(5, "composite", "stage5_composite", "Render graphics + build the FCP timeline"),
    Stage(6, "watch", "stage6_watch", "Watch agent (review the FCP export)", blocking=False),
]

# Stages 1–5 run before Final Cut. Stage 6 runs after. The pipeline hands off a timeline;
# she does the creative edit; then the Watch agent reviews what she exported.
HANDOFF_AFTER = 5


BANNER = r"""
  ┌──────────────────────────────────────────────┐
  │  handmade video pipeline                     │
  │  23.976p · graphics stepped on 2s            │
  │  nothing on screen is generated              │
  │  hands off to Final Cut Pro — never flattens │
  └──────────────────────────────────────────────┘
"""


def preflight(verbose: bool = True) -> list[str]:
    """Check the environment before burning an hour on a run that was going to fail."""
    problems: list[str] = []

    if not shutil.which("ffmpeg"):
        problems.append("ffmpeg not on PATH  →  brew install ffmpeg")

    for mod, hint in (("PIL", "pip install pillow"), ("numpy", "pip install numpy")):
        try:
            importlib.import_module(mod)
        except ImportError:
            problems.append(f"{mod} not importable  →  {hint}")

    try:
        importlib.import_module("whisperx")
    except ImportError:
        if not shutil.which("whisperx"):
            problems.append("whisperx not available  →  pip install whisperx  (stage 1 only)")

    # Case-folded, because all three Canon bodies write `.MOV` and a lower-case glob matched
    # none of them: preflight reported an empty footage/ while sitting on a gigabyte of it.
    if not any(p.suffix.lower() in (".mp4", ".mov", ".mkv", ".m4v", ".avi") for p in C.FOOTAGE.rglob("*")):
        problems.append(f"no footage in {C.FOOTAGE}  →  drop a clip in {C.FOOTAGE / "a-cam"}, or run ./run setup.py to point at your footage")

    grain = list(C.TEXTURES.glob("paper-grain*"))
    if not grain:
        problems.append(
            f"no paper-grain texture in {C.path_label(C.TEXTURES)}/  →  "
            "flat-scan a blank sheet; §4.3 forbids generated noise")

    fonts = list(C.FONTS.glob("*.woff2")) + list(C.FONTS.glob("*.ttf")) + list(C.FONTS.glob("*.otf"))
    if not fonts:
        problems.append(f"no fonts in {C.path_label(C.FONTS)}/  →  add her marker font + Work Sans")

    if verbose:
        print("Preflight")
        if not problems:
            print("  ✓ everything in place")
        for p in problems:
            print(f"  ! {p}")
        print()
    return problems


def run_stage(stage: Stage, extra: list[str], dry_run: bool) -> int:
    print("─" * 70)
    print(f"STAGE {stage.number} — {stage.title}")
    print("─" * 70)
    argv = list(extra)
    if dry_run:
        argv.append("--dry-run")
    started = time.time()
    try:
        mod = importlib.import_module(stage.module)
        code = mod.main(argv)
    except SystemExit as exc:
        code = int(exc.code or 0)
    except Exception as exc:  # noqa: BLE001
        print(f"! stage {stage.number} raised: {exc}", file=sys.stderr)
        code = 1
    print(f"  ({time.time() - started:.1f}s)\n")
    return code or 0


def stage_args(stage: Stage, args) -> list[str]:
    """Per-stage CLI passthrough."""
    out: list[str] = []
    if stage.key == "transcribe":
        out += ["--model", args.model]
        if args.force:
            out.append("--force")
    elif stage.key == "roughcut":
        out += ["--project", args.project]
        if args.aggressive:
            out.append("--aggressive")
        if args.preview:
            out.append("--preview")
    elif stage.key == "plan":
        out += ["--project", args.project]
    elif stage.key == "assets":
        plan = C.PLAN_DIR / f"{args.project}.plan.json"
        if plan.exists():
            out.append(str(plan))
        if args.allow_missing:
            out.append("--allow-missing")
    elif stage.key == "composite":
        plan = C.PLAN_DIR / f"{args.project}.plan.json"
        if plan.exists():
            out.append(str(plan))
        out += ["--aspect", args.aspect]
        if args.no_captions:
            out.append("--no-captions")
    elif stage.key == "watch":
        out += ["--aspect", args.aspect, "--project", args.project]
    return out


def main(argv: list[str] | None = None) -> int:
    cli.preflight()
    ap = argparse.ArgumentParser(
        description="Handmade video pipeline — six stages",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("--from", dest="start", type=int, default=1, help="resume from stage N")
    ap.add_argument("--to", dest="stop", type=int, default=6, help="stop after stage N")
    ap.add_argument("--only", type=int, help="run exactly one stage")
    ap.add_argument("--skip", type=int, nargs="*", default=[], help="skip these stages")
    ap.add_argument("--aspect", default=C.DEFAULT_ASPECT, choices=list(C.ASPECTS))
    ap.add_argument("--project", default="video001", help="project name, used for filenames")
    ap.add_argument("--model", default=C.WHISPER_MODEL, help="whisper model")
    ap.add_argument("--preview", action="store_true",
                    help="stage 2: also render a flattened preview mp4")
    ap.add_argument("--aggressive", action="store_true", help="stage 2: also cut isolated fillers")
    ap.add_argument("--allow-missing", action="store_true", help="stage 4: warn instead of gating")
    ap.add_argument("--no-captions", action="store_true")
    ap.add_argument("--force", action="store_true", help="redo work that already exists")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--json", action="store_true", help="machine-readable preflight (requires --dry-run)")
    ap.add_argument("--progress", choices=("json",), help="emit stage events on stdout; details go to stderr")
    ap.add_argument("--skip-preflight", action="store_true")
    args = ap.parse_args(argv)

    if args.json and not args.dry_run:
        ap.error("--json requires --dry-run")
    if args.json:
        problems = preflight(verbose=False)
        print(json.dumps({"schema_version": 1, "engine_version": C.ENGINE_VERSION,
                          "ready": not problems, "problems": problems,
                          "paths": {key: str(getattr(C, attr)) for key, attr in
                                    (("footage", "FOOTAGE"), ("assets", "ASSETS"), ("build", "BUILD"),
                                     ("cuts", "CUTS"), ("script", "SCRIPT_DIR"), ("templates", "TEMPLATES"))},
                          "whisper_model": C.WHISPER_MODEL}))
        return 1 if problems else 0
    if args.progress:
        with redirect_stdout(sys.stderr):
            problems = [] if args.skip_preflight else preflight()
        if problems and not args.dry_run:
            print(json.dumps({"stage": 0, "state": "fail", "detail": "Resolve the setup check before running."}), flush=True)
            return 1
        selected = [s for s in STAGES if (s.number == args.only if args.only else
                    args.start <= s.number <= args.stop and s.number not in args.skip)]
        if not selected:
            ap.error("no stages selected")
        if not args.dry_run:
            for d in C.ALL_BUILD_DIRS:
                d.mkdir(parents=True, exist_ok=True)
        for stage in selected:
            print(json.dumps({"stage": stage.number, "state": "start", "detail": stage.title}), flush=True)
            with redirect_stdout(sys.stderr):
                code = run_stage(stage, stage_args(stage, args), args.dry_run)
            print(json.dumps({"stage": stage.number, "state": "done" if not code else "fail",
                              "detail": stage.gate_message if code else stage.title}), flush=True)
            if code and stage.blocking:
                return code
        return 0

    print(BANNER)

    if not args.dry_run:
        for d in C.ALL_BUILD_DIRS:
            d.mkdir(parents=True, exist_ok=True)

    problems: list[str] = []
    if not args.skip_preflight:
        problems = preflight()

    if args.only:
        selected = [s for s in STAGES if s.number == args.only]
    else:
        selected = [s for s in STAGES
                    if args.start <= s.number <= args.stop and s.number not in args.skip]

    if not selected:
        print("! no stages selected")
        return 1

    print(f"Running stage(s): {', '.join(str(s.number) for s in selected)}"
          f"{'  [dry run]' if args.dry_run else ''}\n")

    results: dict[int, int] = {}
    for stage in selected:
        code = run_stage(stage, stage_args(stage, args), args.dry_run)
        results[stage.number] = code

        if code != 0 and stage.blocking and not args.dry_run:
            print("═" * 70)
            if stage.gate_message:
                print(f"STOPPED at stage {stage.number}.")
                print(f"  {stage.gate_message}")
            else:
                print(f"STOPPED — stage {stage.number} exited {code}.")
            print("═" * 70)
            return code

    print("═" * 70)
    for s in selected:
        icon = "✓" if results.get(s.number) == 0 else "!"
        print(f"  {icon} stage {s.number} — {s.title}")
    print("═" * 70)

    if HANDOFF_AFTER in results and results[HANDOFF_AFTER] == 0 and not args.dry_run:
        fcpxml = sorted(C.EXPORTS.glob("*.fcpxml"))
        if fcpxml:
            print("\n  OVER TO FINAL CUT")
            print(f"    1. File ▸ Import ▸ XML…   {C.path_label(fcpxml[-1])}")
            print("    2. Import the .itt as captions on the timeline")
            print("    3. Grade, place b-roll at the markers, refine")
            print("    4. Export into build/exports/, then:  "
                  "python scripts/run_pipeline.py --only 6")

    if results.get(6, 0) != 0:
        print("\nThe Watch agent sent work back. Read build/review/*.review.md,")
        print("then write the 'rule going forward' line on each new style_guide.md entry.")
        print("An entry without a testable rule teaches the pipeline nothing.")

    if problems:
        print(f"\n({len(problems)} preflight item(s) still outstanding)")

    return 1 if args.dry_run and (problems or any(results.values())) else 0


if __name__ == "__main__":
    raise SystemExit(main())
