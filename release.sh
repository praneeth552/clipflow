#!/bin/bash

# GitHub Release Script for ClipFlow
# Creates a release with DMG attached

set -e

VERSION="1.0.2"
REPO="praneeth552/clipflow"  # Your GitHub repo
DMG_FILE="./build/ClipFlow-$VERSION.dmg"

echo "📤 GitHub Release Script for ClipFlow v$VERSION"
echo ""

# Check if DMG exists
if [ ! -f "$DMG_FILE" ]; then
    echo "❌ DMG not found: $DMG_FILE"
    echo "   Run: cd ClipFlowApp && ./build.sh"
    exit 1
fi

# Check if gh CLI is installed
if ! command -v gh &> /dev/null; then
    echo "❌ GitHub CLI (gh) not installed"
    echo "   Install: brew install gh"
    echo "   Then: gh auth login"
    exit 1
fi

echo "📦 Creating release v$VERSION..."

# Create release
gh release create "v$VERSION" \
    --repo "$REPO" \
    --title "ClipFlow v$VERSION" \
    --notes "## ClipFlow v$VERSION

### 📥 Installation

1. Download \`ClipFlow-$VERSION.dmg\`
2. Open and drag to Applications
3. Right-click → Open (first time only)
4. Grant Accessibility permissions

### ✨ Features
- Clipboard history (50 items)
- Image preview support
- Terminal-style ↑↓ navigation
- Cursor-following popup
- Smooth animations

### ⌨️ Usage
- \`Cmd+Shift+V\` - Open history
- \`↑/↓\` - Navigate
- \`Enter\` - Paste
- \`Esc\` - Cancel
" \
    "$DMG_FILE"

echo ""
echo "✅ Release created!"
echo "🔗 https://github.com/$REPO/releases/tag/v$VERSION"
