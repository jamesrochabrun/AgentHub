#!/bin/bash
set -e

# Build and create DMG for AgentHub
# Usage: ./scripts/build-dmg.sh [--notarize]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APP_DIR="$PROJECT_ROOT/app"
BUILD_DIR="$PROJECT_ROOT/build"
APP_NAME="AgentHub"
SCHEME="AgentHub"

# Parse arguments
NOTARIZE=false
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --notarize) NOTARIZE=true ;;
    *) echo "Unknown parameter: $1"; exit 1 ;;
  esac
  shift
done

echo "Building $APP_NAME..."

# Clean and create build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Build the app
xcodebuild -project "$APP_DIR/$APP_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
  archive

# Export the app
xcodebuild -exportArchive \
  -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
  -exportPath "$BUILD_DIR" \
  -exportOptionsPlist "$APP_DIR/ExportOptions.plist"

APP_PATH="$BUILD_DIR/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
  echo "Error: App not found at $APP_PATH"
  exit 1
fi

echo "App built successfully at $APP_PATH"

# Notarize if requested
if [ "$NOTARIZE" = true ]; then
  echo "Notarizing $APP_NAME..."

  # Create a zip for notarization
  ditto -c -k --keepParent "$APP_PATH" "$BUILD_DIR/$APP_NAME.zip"

  # Submit for notarization (requires APPLE_ID, TEAM_ID, and APP_PASSWORD env vars)
  xcrun notarytool submit "$BUILD_DIR/$APP_NAME.zip" \
    --apple-id "${APPLE_ID}" \
    --team-id "${TEAM_ID}" \
    --password "${APP_PASSWORD}" \
    --wait

  # Staple the notarization ticket
  xcrun stapler staple "$APP_PATH"

  echo "Notarization complete"
fi

# Create DMG
echo "Creating DMG..."

DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
VOLUME_NAME="$APP_NAME"

# Check if create-dmg is available
if command -v create-dmg &> /dev/null; then
  create-dmg \
    --volname "$VOLUME_NAME" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "$APP_NAME.app" 150 185 \
    --app-drop-link 450 185 \
    --hide-extension "$APP_NAME.app" \
    "$DMG_PATH" \
    "$APP_PATH"
else
  # Fallback to basic DMG creation
  echo "create-dmg not found, using basic hdiutil..."

  TEMP_DMG="$BUILD_DIR/temp.dmg"
  hdiutil create -srcfolder "$APP_PATH" -volname "$VOLUME_NAME" -format UDRW "$TEMP_DMG"
  hdiutil convert "$TEMP_DMG" -format UDZO -o "$DMG_PATH"
  rm "$TEMP_DMG"
fi

echo "DMG created at $DMG_PATH"

# Calculate checksum
shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"
echo "Checksum saved to $DMG_PATH.sha256"

echo "Done!"
