"""setup.py — ask where the video folders live and write paths.json (gitignored).

Run automatically by ./run the first time; re-run any time with `./run setup.py`.
Press Enter to accept the suggestion in [brackets]. Claude reads paths.json (or scripts/config.py)
to find your files, so nothing else needs telling.
"""
import json
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
    old = json.loads((ROOT / "paths.json").read_text()) if (ROOT / "paths.json").is_file() else {}
    print("Where do your files live? Enter = accept the suggestion.\n")
    out = {}
    for key, label in QUESTIONS.items():
        default = old.get(key) or str(suggest(key))
        answer = input(f"{label}\n  {key} [{default}]: ").strip() or default
        path = Path(answer).expanduser().resolve()
        path.mkdir(parents=True, exist_ok=True)
        out[key] = str(path)
    (ROOT / "paths.json").write_text(json.dumps(out, indent=2) + "\n")
    print("\nSaved paths.json:")
    for k, v in out.items():
        print(f"  {k:8} {v}")


if __name__ == "__main__":
    try:
        main()
    except (EOFError, KeyboardInterrupt):
        sys.exit("\nsetup cancelled; nothing saved")
