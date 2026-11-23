#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if [[ ! -f "$SCRIPT_DIR/Config/Local.xcconfig" ]]; then
  echo "Missing ios/Config/Local.xcconfig."
  echo "Copy ios/Config/Local.xcconfig.example -> ios/Config/Local.xcconfig and set your DEVELOPMENT_TEAM, BUNDLE_ID_PREFIX, and DEFAULT_SERVER_URL."
  exit 1
fi

# Auto-detect the first paired physical iPhone if DEVICE_UDID is not provided
DEVICE_UDID="${1:-${DEVICE_UDID:-}}"
if [[ -z "$DEVICE_UDID" ]]; then
  DEVICE_UDID="$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /iPhone/ { for (i=1; i<=NF; i++) if ($i ~ /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}$/ || $i ~ /^[0-9A-Fa-f]{40}$/) { print $i; exit } }')"
fi

if [[ -z "$DEVICE_UDID" ]]; then
  echo "Could not auto-detect a paired physical iPhone. Pass the UDID explicitly:"
  echo "  ./ios/deploy_iphone.sh <IPHONE_UDID>"
  exit 1
fi

echo "==> Regenerating LocalWhisper.xcodeproj..."
xcodegen generate

echo "==> Building LocalWhisper for iOS device..."
xcodebuild \
  -project LocalWhisper.xcodeproj \
  -scheme LocalWhisper \
  -destination "generic/platform=iOS" \
  -configuration Debug \
  -derivedDataPath ./build \
  -allowProvisioningUpdates \
  build

APP_PATH="$SCRIPT_DIR/build/Build/Products/Debug-iphoneos/LocalWhisper.app"
echo "==> Installing $APP_PATH onto device $DEVICE_UDID..."
if xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_PATH"; then
  echo "==> Done! LocalWhisper is installed on your iPhone."
else
  echo "==> Build succeeded, but iPhone ($DEVICE_UDID) is not currently reachable over USB/local Wi-Fi."
  echo "    Re-run ./ios/deploy_iphone.sh when your iPhone is on the same Wi-Fi or plugged in."
  exit 2
fi

echo "==> Cleaning up temporary build directory..."
rm -rf "$SCRIPT_DIR/build"

echo "==> Done! LocalWhisper is installed on your iPhone."
