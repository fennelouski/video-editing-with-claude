#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:---build-only}"
if [[ "$MODE" != --build-only ]]; then
  echo 'usage: script/build_script_candidate.sh [--build-only]' >&2
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
APP_BUNDLE="$ROOT_DIR/.artifacts/DerivedData/Build/Products/Debug/Clauto Editor.app"
# This is the existing app target and bundle identity. Do not stage, rename,
# re-identify, install or launch a second Script/QA application.
echo "$APP_BUNDLE"
