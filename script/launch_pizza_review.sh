#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# The task-local receipt is created only after importing the exact verified movie
# into a separate NAS review project. Never search another checkout or latest path.
PROJECT_PATH="$(./run -c 'import json,pathlib; p=pathlib.Path(".artifacts/PIZZA_REVIEW_PROJECT.json"); r=json.loads(p.read_text()); assert pathlib.Path(r["engineRoot"]).resolve()==pathlib.Path.cwd().resolve(), "Review receipt belongs to another source checkout"; assert r["versionNumber"]==7 and r["movieSHA256"]=="77b9c71437f8b56989e3aaea65507a0592c03a2f7915e8a20f7658dbc5d66595", "Unexpected watched version"; q=pathlib.Path(r["projectPath"]); assert (q/"clauto-project.json").is_file(), "Reconnect Videos and restore the imported review project"; print(q)')"
./script/build_and_run.sh --build-only
/usr/bin/open -n "$ROOT_DIR/dist/Clauto Editor.app" \
  --env "CLAUTO_ENGINE_ROOT=$ROOT_DIR" \
  --env "CLAUTO_OPEN_PROJECT=$PROJECT_PATH" \
  --env "CLAUTO_PROJECT_TAB=Cut" \
  --env "CLAUTO_DEFAULTS_SUITE=com.nathanfennel.Clauto-Pizza-v7-review" \
  --env "CLAUTO_VERIFY_REVIEW_LAUNCH=1"
printf 'Opened Pizza Yeast v7 review project: %s\n' "$PROJECT_PATH"
