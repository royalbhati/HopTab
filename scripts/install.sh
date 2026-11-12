#!/bin/bash
set -euo pipefail

APP_NAME="HopTab"
INSTALL_DIR="/Applications"
BUILD_DIR="build"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$PROJECT_DIR"

# The closed-source HopTabPro package is not in this repo; generate a stub if
# it is missing so a fresh clone builds. No-op when the real package is present.
bash "$PROJECT_DIR/scripts/generate-pro-stub.sh"

echo "Building $APP_NAME (Release)..."
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="-" \
  -quiet

echo "Stopping running instance..."
killall "$APP_NAME" 2>/dev/null || true
sleep 1

echo "Installing to $INSTALL_DIR..."
cp -R "$BUILD_DIR/Build/Products/Release/$APP_NAME.app" "$INSTALL_DIR/$APP_NAME.app"

echo "Launching $APP_NAME..."
open "$INSTALL_DIR/$APP_NAME.app"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_NAME/Info.plist")
echo "Done — $APP_NAME $VERSION installed and running."
