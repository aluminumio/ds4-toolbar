#!/bin/bash
# Install DS4ToolBar as a proper macOS .app bundle
set -e

APP_NAME="DS4ToolBar"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)/.build/release"
APP_DIR="/Applications/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "Building DS4ToolBar..."
cd "$(dirname "$0")"
swift build -c release

echo "Creating .app bundle at $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILD_DIR/ds4toolbar" "$MACOS_DIR/$APP_NAME"

# Create Info.plist (LSUIElement=true = no dock icon)
cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.ds4.toolbar</string>
    <key>CFBundleName</key>
    <string>DwarfStar 4 Toolbar</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "Done! DS4ToolBar installed at $APP_DIR"
echo ""
echo "To use:"
echo "  1. Start ds4-server with stderr logging:"
echo "     ds4-server -m ds4flash.gguf --ctx 1000000 2>/tmp/ds4-server.log &"
echo ""
echo "  2. Launch DS4ToolBar (double-click in /Applications)"
echo ""
echo "  3. For login auto-start, add DS4ToolBar in:"
echo "     System Settings → General → Login Items"
