#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_NAME="Clauto Editor"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
case "$MODE" in
  run|--verify|--debug|--logs|--build-only) ;;
  *) echo "usage: $0 [run|--verify|--debug|--logs|--build-only]" >&2; exit 2 ;;
esac
if [ "$MODE" != --build-only ]; then pkill -x "$APP_NAME" >/dev/null 2>&1 || true; fi
mkdir -p .artifacts dist
xcodebuild -project 'Clauto Editor/Clauto Editor.xcodeproj' -scheme 'Clauto Editor' \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath .artifacts/DerivedData \
  -clonedSourcePackagesDirPath .artifacts/SourcePackages \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM='' build > .artifacts/build.log 2>&1 || {
    tail -60 .artifacts/build.log; exit 1;
  }
ditto '.artifacts/DerivedData/Build/Products/Debug/Clauto Editor.app' "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
if [ "$MODE" = --build-only ]; then echo "$APP_BUNDLE"; exit 0; fi
if [ "$MODE" = --debug ]; then lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"; exit; fi
# Debug builds never check Sparkle feeds and never start Claude turns.
/usr/bin/open -n "$APP_BUNDLE" --env "CLAUTO_ENGINE_ROOT=$ROOT_DIR"
case "$MODE" in
  --verify) sleep 2; pgrep -x "$APP_NAME" >/dev/null; echo "App process running" ;;
  --logs) /usr/bin/log stream --info --style compact --predicate 'process == "Clauto Editor"' ;;
esac
