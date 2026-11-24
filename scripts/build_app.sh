#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="Murmur"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

echo "==> Building $APP_NAME v1.1.0..."
cd "$ROOT_DIR"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

swiftc -parse-as-library -O -swift-version 5 \
    Sources/Murmur/*.swift \
    -lsqlite3 \
    -framework AppKit \
    -framework SwiftUI \
    -framework ApplicationServices \
    -framework CoreServices \
    -framework ServiceManagement \
    -framework Carbon \
    -framework UniformTypeIdentifiers \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

if [ -f "$ROOT_DIR/Resources/AppIcon.icns" ]; then
    cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>Murmur</string>
    <key>CFBundleExecutable</key>
    <string>Murmur</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.deep-octopus.Murmur</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Murmur</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>110</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Auto-detect developer code signing identity if present so TCC permissions persist across updates;
# otherwise fall back to ad-hoc signature.
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
fi

if [ -n "$SIGN_IDENTITY" ]; then
    echo "==> Signing with certificate: $SIGN_IDENTITY"
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
    echo "==> Signing ad-hoc (-)"
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

touch "$APP_BUNDLE"

if [ -w "/Applications" ]; then
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
    if [ -n "$SIGN_IDENTITY" ]; then
        codesign --force --deep --sign "$SIGN_IDENTITY" "/Applications/$APP_NAME.app"
    else
        codesign --force --deep --sign - "/Applications/$APP_NAME.app"
    fi
    echo "==> Installed to /Applications/$APP_NAME.app"
fi

echo "==> Done! App ready at: $APP_BUNDLE"
