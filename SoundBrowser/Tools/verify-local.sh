#!/bin/zsh
set -eu
cd "${0:A:h}/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
export CLAUTO_SFX_TEST_ROOT="${1:?Pass the explicitly materialized eight-sound package root}"
swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
