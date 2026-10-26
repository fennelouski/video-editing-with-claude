#!/usr/bin/env python3
"""Bounded coordinated validation; store execution needs a Clauto UI interval."""
import argparse
import datetime
import json
import os
from pathlib import Path
import signal
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("mode", choices=["core", "app", "store-build", "store"])
parser.add_argument("--seconds", type=int, default=180)
parser.add_argument("--filter", default="ProjectCatalogTests|ProjectRestorationTests|ProjectScriptSelectionTests")
parser.add_argument("--derived-data")
args = parser.parse_args()
os.nice(10)
root = Path(__file__).resolve().parent.parent
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
out = root / ".artifacts" / f"catalog-{args.mode}-{stamp}"
out.mkdir(parents=True)
env = os.environ.copy()
env.update(CLANG_MODULE_CACHE_PATH=str(root / ".build/module-cache"),
           SWIFTPM_MODULECACHE_OVERRIDE=str(root / ".build/module-cache"),
           HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1")
if args.mode == "core":
    command = ["/usr/bin/swift", "test", "--jobs", "2", "-Xswiftc", "-j2",
               "--disable-sandbox", "--skip-update", "--no-parallel", "--scratch-path", ".build/script-core",
               "--filter", args.filter]
elif args.mode == "app":
    if args.derived_data:
        command = ["/usr/bin/xcodebuild", "-project", "Clauto Editor/Clauto Editor.xcodeproj", "-scheme", "Clauto Editor", "-configuration", "Debug", "-jobs", "2", "-derivedDataPath", args.derived_data, "-clonedSourcePackagesDirPath", ".artifacts/SourcePackages", "-disableAutomaticPackageResolution", "-skipPackageUpdates", "CODE_SIGNING_ALLOWED=NO", "build"]
    else:
        command = ["/bin/bash", "script/build_script_candidate.sh", "--build-only"]
else:
    command = ["/usr/bin/xcodebuild", "-project", "Clauto Editor/Clauto Editor.xcodeproj",
               "-scheme", "Clauto Editor", "-configuration", "Debug", "-jobs", "2",
               "-derivedDataPath", args.derived_data or ".artifacts/DerivedData",
               "-clonedSourcePackagesDirPath", ".artifacts/SourcePackages",
               "-disableAutomaticPackageResolution", "-skipPackageUpdates",
               "-destination", "platform=macOS,arch=arm64",
               "-parallel-testing-enabled", "NO",
               "-resultBundlePath", str(out / "Results.xcresult"),
               "CODE_SIGNING_ALLOWED=NO", "build-for-testing" if args.mode == "store-build" else "test-without-building"]
    suites = args.filter.split("|") if args.filter != parser.get_default("filter") else ["ProjectCatalogNativeStoreTests","ProjectRestorationNativeStoreTests"]
    command[-2:-2] = ["-only-testing:Clauto EditorTests/"+name for name in suites]
receipt = {"mode": args.mode, "startedUTC": stamp, "command": command,
           "limitSeconds": args.seconds, "nice": os.getpriority(os.PRIO_PROCESS, 0), "log": str(out / "output.log")}
with (out / "output.log").open("wb") as log:
    process = subprocess.Popen(command, cwd=root, env=env, stdout=log,
                               stderr=subprocess.STDOUT, start_new_session=True)
    receipt["processGroup"] = process.pid
    try:
        receipt["exitCode"] = process.wait(timeout=args.seconds)
    except subprocess.TimeoutExpired:
        receipt["timedOut"] = True
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        receipt["exitCode"] = process.returncode
receipt["endedUTC"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
try:
    os.killpg(process.pid, 0)
    receipt["ownedGroupAbsent"] = False
except ProcessLookupError:
    receipt["ownedGroupAbsent"] = True
(out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps(receipt, indent=2), flush=True)
raise SystemExit(0 if receipt["exitCode"] == 0 else 1)
