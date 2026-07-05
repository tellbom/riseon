#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-$HOME/riseon}"
PROJECT_NAME="${PROJECT_NAME:-RiseOn.xcodeproj}"
SCHEME="${SCHEME:-RiseOn}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA="${DERIVED_DATA:-$PROJECT_DIR/.derivedData}"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/RiseOn.app"

cd "$PROJECT_DIR"

echo "== RiseOn renew =="
echo "Project: $PROJECT_DIR/$PROJECT_NAME"
echo "Scheme:  $SCHEME"
echo

if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  echo "Xcode first-launch tasks are not complete. Open Xcode once or run:"
  echo "  sudo xcodebuild -runFirstLaunch"
  exit 1
fi

echo "== Available destinations =="
xcodebuild -project "$PROJECT_NAME" -scheme "$SCHEME" -showdestinations || true
echo

if [[ -n "${DESTINATION:-}" ]]; then
  destination="$DESTINATION"
else
  destination="$(xcodebuild -project "$PROJECT_NAME" -scheme "$SCHEME" -showdestinations 2>/dev/null \
    | awk '/platform:iOS,/ && /id:/ && $0 !~ /DVTiPhonePlaceholder/ {
        line=$0
        sub(/^.*id:/, "", line)
        sub(/,.*/, "", line)
        gsub(/^ +| +$/, "", line)
        print "platform=iOS,id=" line
        exit
      }')"
fi

if [[ -z "$destination" ]]; then
  cat <<'MSG'
No connected iPhone was found from command line.

Before renewing:
  1. Unlock the iPhone.
  2. Keep the iPhone and Mac mini on the same Wi-Fi, or connect by USB.
  3. Trust this Mac on the iPhone if prompted.
  4. Make sure Developer Mode is enabled on iPhone and Apple Watch.
  5. In Xcode > Devices and Simulators, wait until the iPhone/Watch are ready.

You can also pass a destination manually:
  DESTINATION='platform=iOS,name=Your iPhone Name' zsh ~/riseon/renew.sh
  DESTINATION='platform=iOS,id=DEVICE_UDID' zsh ~/riseon/renew.sh
MSG
  exit 2
fi

echo "== Building and renewing signing =="
echo "Destination: $destination"

xcodebuild \
  -project "$PROJECT_NAME" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$destination" \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  build

echo
echo "== Build finished =="

if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app was not found at:"
  echo "  $APP_PATH"
  echo "The signing/profile renewal build succeeded, but installation was skipped."
  exit 0
fi

if ! command -v xcrun >/dev/null 2>&1 || ! xcrun devicectl --help >/dev/null 2>&1; then
  echo "xcrun devicectl is not available. Build succeeded; install from Xcode if needed."
  exit 0
fi

device_id="$(printf '%s\n' "$destination" | sed -n 's/^.*id=\([^,]*\).*$/\1/p')"

if [[ -z "$device_id" ]]; then
  echo "Build succeeded. Installation skipped because the destination did not include a device id."
  echo "Use a destination with id=DEVICE_UDID to auto-install."
  exit 0
fi

echo
echo "== Installing to iPhone =="
xcrun devicectl device install app --device "$device_id" "$APP_PATH"

echo
echo "Renew complete."
