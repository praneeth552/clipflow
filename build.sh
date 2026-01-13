#!/bin/bash

# ClipFlow Build Script
# Creates a signed .app bundle and .dmg installer

set -e

APP_NAME="ClipFlow"
VERSION="1.0.2"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "🚀 Building $APP_NAME v$VERSION..."

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Create .app bundle structure
echo "📦 Creating .app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Compile Swift code with optimization
echo "🔨 Compiling Swift (optimized)..."
swiftc -O -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    ClipFlowApp.swift \
    -framework AppKit \
    -framework Carbon

# Copy app icon (for Finder/Dock)
if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/"
    echo "✅ App icon copied (icns)"
fi

# Copy menu bar icon
if [ -f "icon.png" ]; then
    cp icon.png "$APP_BUNDLE/Contents/MacOS/"
    echo "✅ Menu bar icon copied (png)"
fi

# Create Info.plist
echo "📝 Creating Info.plist..."
cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.clipflow.app</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2024. MIT License.</string>
</dict>
</plist>
EOF

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Ad-hoc code signing (reduces Gatekeeper warnings)
echo "🔏 Ad-hoc signing..."
# Remove extended attributes that break codesign
xattr -cr "$APP_BUNDLE"
codesign --force --deep --sign - "$APP_BUNDLE"
echo "✅ App signed (ad-hoc)"

echo "✅ .app bundle created: $APP_BUNDLE"

# Create DMG installer
echo ""
echo "💿 Creating DMG installer..."

DMG_NAME="$APP_NAME-$VERSION"
DMG_DIR="$BUILD_DIR/dmg"
DMG_FILE="$BUILD_DIR/$DMG_NAME.dmg"

mkdir -p "$DMG_DIR"
cp -R "$APP_BUNDLE" "$DMG_DIR/"

# Create symlink to Applications folder
ln -s /Applications "$DMG_DIR/Applications"

# Create README for DMG
cat > "$DMG_DIR/README.txt" << EOF
╔═══════════════════════════════════════════════════════════════╗
║                 ClipFlow v$VERSION                              ║
║         Clipboard History for macOS                           ║
╚═══════════════════════════════════════════════════════════════╝

INSTALLATION
────────────
1. Drag ClipFlow.app to the Applications folder
2. Open ClipFlow from Applications
3. Grant Accessibility permissions when prompted

⚠️  FIRST LAUNCH (unsigned app)
─────────────────────────────────
If you see "unidentified developer" warning:
  → Right-click on ClipFlow.app → Open → Click "Open"
  
Or: System Settings → Privacy & Security → "Open Anyway"

USAGE
─────
• Cmd+Shift+V  →  Open history popup
• ↑/↓ arrows   →  Navigate through history
• Enter        →  Paste selected item
• Esc          →  Cancel

PERMISSIONS
───────────
Grant Accessibility access:
  System Settings → Privacy & Security → Accessibility → Add ClipFlow

Enjoy! 🎉
EOF

# Create DMG
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$DMG_FILE"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "✅ BUILD COMPLETE!"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "📦 Outputs:"
echo "   • App Bundle: $APP_BUNDLE"
echo "   • DMG Installer: $DMG_FILE"
echo ""
echo "🚀 Install: Drag ClipFlow.app to /Applications"
echo "📤 Share: Send the .dmg file to other users"
echo ""
