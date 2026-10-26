#!/usr/bin/env python3
"""Existing app identity, isolated build products, bounded low-priority checks."""
import argparse
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument("mode", choices=["core", "app", "store-build", "store"])
parser.add_argument("--seconds", type=int, default=180)
parser.add_argument("--full-core", action="store_true")
parser.add_argument("--regression-batch", type=int, choices=[1, 2, 3])
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
suite = ".*" if args.full_core else "StoragePlanningTests|StorageMigrationTests|StorageCacheTests|StorageSetupControllerTests|ProjectCatalogTests|ProjectRestorationTests|ProjectScriptSelectionTests"
if args.regression_batch:
    import re
    names = set()
    for source in (root / "Clauto Editor/Clauto EditorTests").glob("*.swift"):
        names.update(re.findall(r"(?:struct|class)\s+(\w+Tests)\b", source.read_text()))
    names = {name for name in names if "Native" not in name and name != "FrameReviewAppKitStructureTests"}
    def batch(name):
        if name == "ConversationHistoryTests":
            return 1
        return 3 if name.startswith(("Theme", "Transcript", "Voice", "Workflow", "Workspace")) else 2
    suite = "|".join(sorted(name for name in names if batch(name) == args.regression_batch))
if args.mode in ["store-build", "store"]:
    suite = "StorageSetupNativeStoreTests|ProjectCatalogNativeStoreTests|ProjectRestorationNativeStoreTests"
command = [sys.executable, str(root / "script/verify_project_catalog.py"), args.mode,
           "--seconds", str(args.seconds), "--filter", suite,
           "--derived-data", str(root / ".artifacts/StorageDerivedData")]
raise SystemExit(subprocess.run(command, cwd=root).returncode)
