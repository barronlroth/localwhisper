#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if [[ ! -f "$SCRIPT_DIR/Config/Local.xcconfig" ]]; then
  echo "Missing ios/Config/Local.xcconfig."
  exit 1
fi

# Extract Team ID and bundle IDs from Local.xcconfig / Base.xcconfig
eval "$(python3 - << 'EOF'
import pathlib, re, shlex
vals = {}
for name in ("Config/Base.xcconfig", "Config/Local.xcconfig"):
    p = pathlib.Path(name)
    if not p.exists():
        continue
    for line in p.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("//") or line.startswith("#"):
            continue
        if "=" in line:
            k, v = line.split("=", 1)
            vals[k.strip()] = v.strip()

def expand(s):
    for _ in range(5):
        s = re.sub(r"\$\(([^)]+)\)", lambda m: vals.get(m.group(1), m.group(0)), s)
    return s

team = expand(vals.get("DEVELOPMENT_TEAM", ""))
app_id = expand(vals.get("APP_BUNDLE_ID", ""))
kb_id = expand(vals.get("KEYBOARD_BUNDLE_ID", ""))
print(f"TEAM_ID={shlex.quote(team)}")
print(f"APP_BUNDLE_ID={shlex.quote(app_id)}")
print(f"KB_BUNDLE_ID={shlex.quote(kb_id)}")
EOF
)"

APP_PROFILE_NAME="${APP_STORE_PROFILE_NAME:-LocalWhisper AppStore}"
KB_PROFILE_NAME="${KB_STORE_PROFILE_NAME:-LocalWhisper Keyboard AppStore}"
BUILD_NUMBER="${1:-$(date +%Y%m%d%H%M)}"

SIGN_KC="${DISTRIBUTION_KEYCHAIN:-$HOME/.appstoreconnect/signing/distribution.keychain-db}"
SIGN_KC_PASS_FILE="${DISTRIBUTION_KEYCHAIN_PASS_FILE:-$HOME/.appstoreconnect/signing/.kc_pass}"
EXTRA_SIGN_FLAGS=()
ORIG_KEYCHAINS=()

if [[ -f "$SIGN_KC" && -f "$SIGN_KC_PASS_FILE" ]]; then
  security unlock-keychain -p "$(cat "$SIGN_KC_PASS_FILE")" "$SIGN_KC"
  while IFS= read -r kc; do
    kc="${kc//\"/}"
    kc="${kc#"${kc%%[![:space:]]*}"}"
    [[ -n "$kc" ]] && ORIG_KEYCHAINS+=("$kc")
  done < <(security list-keychains -d user)
  security list-keychains -d user -s "$SIGN_KC" "${ORIG_KEYCHAINS[@]}"
  trap 'if [[ ${#ORIG_KEYCHAINS[@]} -gt 0 ]]; then security list-keychains -d user -s "${ORIG_KEYCHAINS[@]}"; fi' EXIT
  EXTRA_SIGN_FLAGS+=(OTHER_CODE_SIGN_FLAGS="--keychain $SIGN_KC")
fi

echo "==> Regenerating LocalWhisper.xcodeproj..."
xcodegen generate

ARCHIVE_PATH="$SCRIPT_DIR/build/LocalWhisper.xcarchive"
EXPORT_DIR="$SCRIPT_DIR/build/export"
EXPORT_PLIST="$SCRIPT_DIR/build/ExportOptions.plist"
mkdir -p "$SCRIPT_DIR/build"

cat > "$EXPORT_PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>teamID</key>
  <string>${TEAM_ID}</string>
  <key>signingCertificate</key>
  <string>Apple Distribution</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>${APP_BUNDLE_ID}</key>
    <string>${APP_PROFILE_NAME}</string>
    <key>${KB_BUNDLE_ID}</key>
    <string>${KB_PROFILE_NAME}</string>
  </dict>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
EOF

echo "==> Archiving LocalWhisper (build $BUILD_NUMBER)..."
xcodebuild \
  -project LocalWhisper.xcodeproj \
  -scheme LocalWhisper \
  -destination "generic/platform=iOS" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Apple Distribution" \
  APP_PROVISIONING_PROFILE="$APP_PROFILE_NAME" \
  KB_PROVISIONING_PROFILE="$KB_PROFILE_NAME" \
  "${EXTRA_SIGN_FLAGS[@]}" \
  archive

echo "==> Exporting signed App Store IPA..."
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST"

IPA_PATH="$(find "$EXPORT_DIR" -name "*.ipa" -maxdepth 2 | head -n 1)"
echo "==> Built IPA: $IPA_PATH"

APP_ASC_ID="${ASC_APP_ID:-$(asc apps list --bundle-id "$APP_BUNDLE_ID" --output json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); items=d.get('data',d) if isinstance(d,dict) else d; print(items[0]['id'] if items else '')" || true)}"

if [[ -z "$APP_ASC_ID" ]]; then
  echo ""
  echo "==> IPA is built & signed cleanly at: $IPA_PATH"
  echo "    No App Store Connect app record exists yet for $APP_BUNDLE_ID."
  echo "    Create it once at https://appstoreconnect.apple.com/apps (+ -> New App -> Bundle ID: $APP_BUNDLE_ID),"
  echo "    then re-run ./ios/upload_testflight.sh to upload directly to TestFlight!"
  exit 0
fi

echo "==> Uploading IPA to TestFlight (ASC App ID: $APP_ASC_ID)..."
asc builds upload --app "$APP_ASC_ID" --ipa "$IPA_PATH"

echo "==> Cleaning up temporary build artifacts..."
rm -rf "$SCRIPT_DIR/build"
echo "==> Done! Build $BUILD_NUMBER uploaded to TestFlight."
