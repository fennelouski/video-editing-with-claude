"""Fail before a pipeline command can create a local fallback for a missing NAS."""
import json
import os
from pathlib import Path
import sys

from canon_ingest import IngestError, verify_mount


def main():
    path = Path(__file__).parents[1] / "storage.json"
    if not path.is_file():
        return 0
    cfg = json.loads(path.read_text())
    verify_mount(cfg)
    paths = json.loads(Path(os.environ.get("CLAUTO_PATHS", str(path.parent / "paths.json"))).read_text())
    for key in ("footage", "assets", "build", "cuts", "script"):
        if key not in paths:
            continue
        folder = Path(paths[key])
        if not folder.is_relative_to(Path(cfg["destination"])) or folder.resolve(strict=False) != folder:
            raise IngestError(f"{key} must stay below the verified NAS workspace")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (IngestError, OSError, ValueError) as exc:
        print(f"Storage unavailable: {exc}; no media folders created", file=sys.stderr)
        raise SystemExit(1)
