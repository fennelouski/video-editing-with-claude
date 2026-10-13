"""setup.py — ask where the video folders live and write paths.json (gitignored).

Run automatically by ./run the first time; re-run any time with `./run setup.py`.
Press Enter to accept the suggestion in [brackets]. Claude reads paths.json (or scripts/config.py)
to find your files, so nothing else needs telling.
"""
import json
import argparse
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
QUESTIONS = {
    "footage": "Camera footage (a-cam, b-cam, broll, audio subfolders)",
    "assets": "Assets: music, cutouts, textures, foley, luts, fonts",
    "build": "Build output: transcripts, renders, exports (large, regenerable)",
    "cuts": "Finished cuts: scripts, shot lists, FCPXML per video",
}


def suggest(key: str) -> Path:
    for parent in [ROOT, *list(ROOT.parents)[:3]]:
        if (parent / key).is_dir() and any((parent / key).iterdir()):
            return parent / key
    return ROOT / key


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for key in (*QUESTIONS, "script", "templates"):
        parser.add_argument(f"--{key}")
    parser.add_argument("--paths", default=os.environ.get("CLAUTO_PATHS", str(ROOT / "paths.json")))
    parser.add_argument("--whisper-model", choices=("small", "medium", "large-v3"))
    args = parser.parse_args()
    supplied = any(getattr(args, key) for key in QUESTIONS)
    if supplied and not all(getattr(args, key) for key in QUESTIONS):
        parser.error("non-interactive setup needs --footage, --assets, --build and --cuts")
    target = Path(args.paths).expanduser().resolve()
    old = json.loads(target.read_text()) if target.is_file() else {}
    if not supplied:
        print("Where do your files live? Enter = accept the suggestion.\n")
    out = {}
    for key in ("script", "templates"):
        if old.get(key):
            value = Path(old[key]).expanduser()
            out[key] = str((value if value.is_absolute() else target.parent / value).resolve())
    for key, label in QUESTIONS.items():
        default = old.get(key) or str(suggest(key))
        answer = getattr(args, key) if supplied else (input(f"{label}\n  {key} [{default}]: ").strip() or default)
        path = Path(answer).expanduser().resolve()
        out[key] = str(path)
    for key in ("script", "templates"):
        if getattr(args, key):
            out[key] = str(Path(getattr(args, key)).expanduser().resolve())
    # Never fabricate a directory under /Volumes when a removable/NAS drive is absent.
    for value in (str(target.parent), *out.values()):
        parts = Path(value).parts
        if len(parts) > 2 and parts[1] == "Volumes" and not os.path.ismount(Path("/Volumes") / parts[2]):
            parser.error(f"drive {parts[2]} is unavailable; reconnect it and retry")
    for value in out.values():
        Path(value).mkdir(parents=True, exist_ok=True)
    out["whisper_model"] = args.whisper_model or old.get("whisper_model", "large-v3")
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(out, indent=2) + "\n")
    temporary.replace(target)
    print(f"\nSaved {target}:")
    for k, v in out.items():
        print(f"  {k:8} {v}")


if __name__ == "__main__":
    try:
        main()
    except (EOFError, KeyboardInterrupt):
        sys.exit("\nsetup cancelled; nothing saved")
