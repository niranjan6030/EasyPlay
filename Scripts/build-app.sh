#!/bin/bash
#
# Assembles EasyPlay.app from the SwiftPM build.
#
# There is no .xcodeproj on purpose: the project builds with the Command Line
# Tools alone, so it can be cloned and built on a Mac without Xcode installed.
# Everything Xcode would do for an app bundle — Info.plist, resource layout,
# code signature — happens here instead, in about forty readable lines.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
APP="$ROOT/build/EasyPlay.app"
VERSION="0.1.0"

echo "Building EasyPlay ($CONFIGURATION)…"
cd "$ROOT"
swift build -c "$CONFIGURATION" --product EasyPlayApp

BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/EasyPlayApp" "$APP/Contents/MacOS/EasyPlay"

# Presets go into the app's own Resources, which is where RecipeLibrary looks
# first — the SwiftPM resource bundle's layout doesn't survive into a .app.
cp -R "$ROOT/Sources/EasyPlayKit/Resources/Recipes" "$APP/Contents/Resources/Recipes"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>EasyPlay</string>
    <key>CFBundleDisplayName</key>           <string>EasyPlay</string>
    <key>CFBundleExecutable</key>            <string>EasyPlay</string>
    <key>CFBundleIdentifier</key>            <string>com.easyplay.EasyPlay</string>
    <key>CFBundleVersion</key>               <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Orchestrates Wine and DXVK. It does not reimplement them.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. EasyPlay is not sandboxed and cannot be: it exists to run
# other people's binaries at arbitrary paths, which the sandbox exists to stop.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

echo "Built $APP"
echo "Run it with: open \"$APP\""
