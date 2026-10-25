#!/bin/zsh
set -eu
cd "${0:A:h}/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
bin_dir=$(swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security --show-bin-path)
app="$PWD/.build/Clauto Sound Browser.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/ClautoSoundBrowser" "$app/Contents/MacOS/ClautoSoundBrowser"
cp -R "$bin_dir/ClautoSoundBrowser_SoundBrowserCore.bundle" "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.clauto.sound-browser.prototype</string>
<key>CFBundleName</key><string>Clauto Sound Browser</string>
<key>CFBundleExecutable</key><string>ClautoSoundBrowser</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>com.clauto.sound-reference</string>
<key>UTTypeDescription</key><string>Clauto sound reference</string>
<key>UTTypeConformsTo</key><array><string>public.json</string></array>
</dict></array>
</dict></plist>
PLIST
print -r -- "$app"
