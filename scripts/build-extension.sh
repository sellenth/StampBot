#!/bin/bash

# Build script for Drag-n-Stamp Chrome Extension
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

# Create the zip file
ZIP_NAME="drag-n-stamp-extension-v$VERSION-$TIMESTAMP.zip"
ZIP_PATH="$BUILD_DIR/$ZIP_NAME"

echo "Creating $ZIP_NAME..."

# Zip the extension directory, excluding development files
cd "$PROJECT_ROOT"
zip -r "$ZIP_PATH" extension/ \
  -x "extension/icons/generate-icons.html" \
  -x "extension/.DS_Store" \
  -x "extension/*/.DS_Store"

# Create a symlink to latest
cd "$BUILD_DIR"
rm -f drag-n-stamp-extension-latest.zip
ln -s "$ZIP_NAME" drag-n-stamp-extension-latest.zip

echo "✅ Extension built successfully!"
echo "📦 File: $ZIP_PATH"
echo "📏 Size: $(du -h "$ZIP_PATH" | cut -f1)"
echo "🔗 Latest: $BUILD_DIR/drag-n-stamp-extension-latest.zip"

# Show contents
echo ""
echo "📋 Contents:"
unzip -l "$ZIP_PATH" | grep -E '\.(js|html|css|json|png)$' | awk '{print "   " $4}'