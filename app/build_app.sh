#!/bin/zsh
# Builds Clickwheel.app into app/build/. No signing needed to run it locally.
# Usage: app/build_app.sh            then: open app/build/Clickwheel.app
set -euo pipefail
APP_DIR=${0:A:h}
REPO=${APP_DIR:h}
OUT="$APP_DIR/build/Clickwheel.app"
cd "$APP_DIR"
swift build -c release
BIN=$(swift build -c release --show-bin-path)/Clickwheel

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/Clickwheel"

# icon
ICONSET="$APP_DIR/build/Clickwheel.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
swift "$APP_DIR/make_icon.swift" "$APP_DIR/build/icon_1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$APP_DIR/build/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$APP_DIR/build/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/AppIcon.icns"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Clickwheel</string>
  <key>CFBundleDisplayName</key><string>Clickwheel</string>
  <key>CFBundleIdentifier</key><string>io.github.clickwheel</string>
  <key>CFBundleExecutable</key><string>Clickwheel</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSRemovableVolumesUsageDescription</key><string>Clickwheel reads iPod_Control/Device/SysInfo on the iPod to identify the model and firmware version. It never changes files on the iPod.</string>
  <key>NSAppleEventsUsageDescription</key><string>Clickwheel asks macOS for administrator rights to read and write the iPod's firmware partition.</string>
  <key>ClickwheelRepoPath</key><string>$REPO</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$OUT" >/dev/null 2>&1 || true
echo "built $OUT"
