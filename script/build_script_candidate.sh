#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:---build-only}"
if [[ "$MODE" != --build-only && "$MODE" != --launch-fixture ]]; then
  echo 'usage: script/build_script_candidate.sh [--build-only | --launch-fixture SYNTHETIC_PROJECT]' >&2
  exit 2
fi
mkdir -p .artifacts
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/xcode-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
xcodebuild -project 'Clauto Editor/Clauto Editor.xcodeproj' -scheme 'Clauto Editor' \
  -configuration Debug -derivedDataPath .artifacts/DerivedData \
  -clonedSourcePackagesDirPath .artifacts/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build \
  > .artifacts/script-editor-build.log 2>&1 || { tail -45 .artifacts/script-editor-build.log; exit 1; }
APP_BUNDLE="$ROOT_DIR/.artifacts/Clauto Script QA.app"
ditto '.artifacts/DerivedData/Build/Products/Debug/Clauto Editor.app' "$APP_BUNDLE"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.clauto.editor.scriptqa' "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Clauto Script QA' "$APP_BUNDLE/Contents/Info.plist"
codesign --force --deep --sign - "$APP_BUNDLE" > .artifacts/script-candidate-sign.log 2>&1
codesign --verify --deep --strict "$APP_BUNDLE"
echo "$APP_BUNDLE"
if [[ "$MODE" == --build-only ]]; then exit 0; fi
FIXTURE_DIR="${2:?Provide the synthetic acceptance project folder}"
# This QA launcher deliberately accepts only its generated local fixture. It
# never restores production recents, stops another process, or installs an app.
python3 - "$ROOT_DIR" "$FIXTURE_DIR" <<'PY'
import json, sys
from pathlib import Path
root, fixture = map(lambda p: Path(p).resolve(), sys.argv[1:])
if not fixture.is_relative_to(root / '.artifacts'):
    raise SystemExit('Choose a synthetic project under this worktree’s .artifacts folder.')
manifest = json.loads((fixture / 'clauto-project.json').read_text())
if manifest['name'] != 'Synthetic Script QA':
    raise SystemExit('Only the generated Synthetic Script QA project can be launched here.')
PY
# Invoke the Xcode app's own bundle executable with explicit environment values.
# LaunchServices may select a previously launched empty QA instance before the
# fixture environment is attached; this keeps the process/fixture association
# concrete without changing global launch settings.
nohup env CLAUTO_ENGINE_ROOT="$ROOT_DIR" \
  CLAUTO_PROJECTS_ROOT="$ROOT_DIR/.artifacts/script-projects" \
  CLAUTO_DEFAULTS_SUITE=com.clauto.editor.scriptqa.fixture1 \
  CLAUTO_PROJECT_TAB=Script CLAUTO_OPEN_PROJECT="$FIXTURE_DIR" \
  "$APP_BUNDLE/Contents/MacOS/Clauto Editor" > .artifacts/script-qa-launch.log 2>&1 &
QA_PID=$!
echo "$QA_PID" > .artifacts/script-qa.pid
echo "Synthetic QA process: $QA_PID"
