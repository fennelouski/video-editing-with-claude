#!/bin/zsh
set -eu
cd "${0:A:h}/.."
package_root="${1:?Pass the explicitly materialized eight-sound package root}"
output="${2:-$PWD/.qa}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
bin_dir=$(swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security --show-bin-path)
"$bin_dir/ClautoSoundBrowser" --qa-output "$output" --qa-library "$package_root"
