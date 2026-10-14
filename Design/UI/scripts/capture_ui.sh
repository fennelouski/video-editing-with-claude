#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_DIR"
CAPTURE_OUTPUT="${1:-Design/UI/previews/round-1}"
CAPTURE_BIN="/tmp/clauto-synthetic-ui-capture"
# This is a verification CLI, not the app executable. No Updater or @main app is linked.
SOURCES=("Clauto Editor/Clauto Editor/ContentView.swift")
while IFS= read -r source; do SOURCES+=("$source"); done < <(rg --files 'Clauto Editor/Clauto Editor/Views' 'Clauto Editor/Clauto Editor/Models' 'Clauto Editor/Clauto Editor/Services' -g '*.swift' -g '!Updater.swift' | sort)
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos26.0 -D DEBUG \
  -Xfrontend -disable-sandbox -module-cache-path /tmp/clauto-identity-module-cache \
  "${SOURCES[@]}" Design/UI/scripts/CaptureUI.swift -o "$CAPTURE_BIN"
"$CAPTURE_BIN" "$CAPTURE_OUTPUT"
