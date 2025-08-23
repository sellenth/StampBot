#!/bin/bash

# Build script for Drag-n-Stamp Chrome/Firefox Extension
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
EXTENSION_DIR="$PROJECT_ROOT/extension"
BUILD_DIR="$PROJECT_ROOT/build"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
VERSION=$(grep '"version"' "$EXTENSION_DIR/manifest.json" | sed 's/.*"version": "\(.*\)".*/\1/')

echo "Building Drag-n-Stamp Extension v$VERSION"

# Create build directory
mkdir -p "$BUILD_DIR"

# Clean any existing zip files
rm -f "$BUILD_DIR"/drag-n-stamp-extension-*.zip

# Create Chrome version
CHROME_ZIP_NAME="drag-n-stamp-extension-chrome-v$VERSION-$TIMESTAMP.zip"
CHROME_ZIP_PATH="$BUILD_DIR/$CHROME_ZIP_NAME"

echo "Creating Chrome version: $CHROME_ZIP_NAME..."

# Zip the extension directory for Chrome
cd "$EXTENSION_DIR"
zip -r "$CHROME_ZIP_PATH" . \
  -x "*.md" \
  -x "manifest-firefox.json" \
  -x "icons/generate-icons.html" \
  -x "icons/.github/*" \
  -x ".DS_Store" \
  -x "*/.DS_Store"

# Create Firefox version
FIREFOX_ZIP_NAME="drag-n-stamp-extension-firefox-v$VERSION-$TIMESTAMP.zip"
FIREFOX_ZIP_PATH="$BUILD_DIR/$FIREFOX_ZIP_NAME"

echo "Creating Firefox version: $FIREFOX_ZIP_NAME..."

# Temporarily swap manifest files for Firefox build
cd "$EXTENSION_DIR"
mv manifest.json manifest-chrome.json
mv manifest-firefox.json manifest.json

# Zip the extension directory for Firefox
zip -r "$FIREFOX_ZIP_PATH" . \
  -x "*.md" \
  -x "manifest-chrome.json" \
  -x "icons/generate-icons.html" \
  -x "icons/.github/*" \
  -x ".DS_Store" \
  -x "*/.DS_Store"

# Restore original manifest files
mv manifest.json manifest-firefox.json
mv manifest-chrome.json manifest.json

# Create latest symlinks
cd "$BUILD_DIR"
rm -f drag-n-stamp-extension-chrome-latest.zip drag-n-stamp-extension-firefox-latest.zip
cp "$CHROME_ZIP_NAME" drag-n-stamp-extension-chrome-latest.zip
cp "$FIREFOX_ZIP_NAME" drag-n-stamp-extension-firefox-latest.zip

echo "✅ Extensions built successfully!"
echo ""
echo "📦 Chrome: $CHROME_ZIP_PATH"
echo "📏 Size: $(du -h "$CHROME_ZIP_PATH" | cut -f1)"
echo ""
echo "📦 Firefox: $FIREFOX_ZIP_PATH"
echo "📏 Size: $(du -h "$FIREFOX_ZIP_PATH" | cut -f1)"
echo ""
echo "🔗 Latest Chrome: $BUILD_DIR/drag-n-stamp-extension-chrome-latest.zip"
echo "🔗 Latest Firefox: $BUILD_DIR/drag-n-stamp-extension-firefox-latest.zip"