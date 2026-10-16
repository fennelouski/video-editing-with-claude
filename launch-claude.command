#!/bin/sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

if [ ! -x "$here/.venv/bin/python" ]; then
    echo "! no project venv at $here/.venv" >&2
    echo "  Create it with Python 3.12 and install the project requirements." >&2
    exit 1
fi

"$here/.venv/bin/python" "$here/scripts/check_storage.py"

if ! command -v claude >/dev/null 2>&1; then
    echo "! Claude Code CLI is not available on PATH; install it from its official source first." >&2
    exit 127
fi

exec claude
