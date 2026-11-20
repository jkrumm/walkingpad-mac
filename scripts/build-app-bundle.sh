#!/usr/bin/env bash
# Wrap a compiled king-smith-walkingpad-mac binary into a macOS .app bundle.
#
# Usage:  scripts/build-app-bundle.sh <binary-path> <version> <output-app-path>
#
# Why this script exists: macOS CoreBluetooth silently denies bare CLI binaries.
# The daemon must run from a .app bundle whose Info.plist declares the
# NSBluetoothAlwaysUsageDescription + NSBluetoothPeripheralUsageDescription
# strings. See PRD §12.
#
# The bundle is signed with the Developer ID identity when the machine has one, ad-hoc
# otherwise (see the signing block below for why the difference matters to Bluetooth).

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <binary> <version> <output.app>" >&2
  exit 64 # EX_USAGE
fi

BINARY=$1
VERSION=$2
APP_PATH=$3

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLIST_TMPL="$SCRIPT_DIR/Info.plist.tmpl"
ICON_PNG="$SCRIPT_DIR/icon.png"
BUILD_ICNS="$SCRIPT_DIR/build-icns.sh"

if [[ ! -x "$BINARY" ]]; then
  echo "error: binary not found or not executable: $BINARY" >&2
  exit 1
fi
if [[ ! -f "$PLIST_TMPL" ]]; then
  echo "error: Info.plist template missing: $PLIST_TMPL" >&2
  exit 1
fi

BINARY_BASENAME=$(basename "$BINARY")
APP_DIR="$APP_PATH/Contents"

# Remove any previous bundle so stale Info.plist version strings don't linger.
rm -rf "$APP_PATH"
mkdir -p "$APP_DIR/MacOS" "$APP_DIR/Resources"

# Substitute __VERSION__ into the Info.plist. Use a temp file so the template
# stays read-only on disk.
sed "s/__VERSION__/${VERSION//\//_}/g" "$PLIST_TMPL" > "$APP_DIR/Info.plist"

# Build the .icns at bundle time from scripts/icon.png (single source of
# truth). Skips silently if the source is missing — the bundle still runs
# headlessly, just shows a generic Finder icon.
if [[ -f "$ICON_PNG" && -x "$BUILD_ICNS" ]]; then
  "$BUILD_ICNS" "$ICON_PNG" "$APP_DIR/Resources/AppIcon.icns"
fi

# Copy the binary; preserve the executable bit. Use install to set 0755 explicitly.
install -m 0755 "$BINARY" "$APP_DIR/MacOS/$BINARY_BASENAME"

# Strip any quarantine xattrs that would block CoreBluetooth TCC. Safe to ignore
# the exit code — if there are no xattrs there is nothing to strip.
xattr -cr "$APP_PATH" 2>/dev/null || true

# Sign the bundle. macOS TCC keeps the Bluetooth grant against the bundle's
# designated requirement. An ad-hoc signature (--sign -) has the cdhash as its
# requirement, which changes on every rebuild: tccd logs "Failed to match existing
# code requirement ... kTCCServiceBluetoothAlways", prompts on the mini display and the
# daemon cannot start BLE until someone clicks Allow. A Developer ID signature has a
# requirement built from the bundle id and the team, identical across builds, so the
# grant survives a deploy.
#
#   SIGN_IDENTITY unset  the team's "Developer ID Application" certificate when the
#                        keychain search list holds one, else ad-hoc with a warning
#   SIGN_IDENTITY=-      ad-hoc (CI, machines without the certificate)
#   SIGN_IDENTITY=<id>   that identity (SHA-1 or name); failure is fatal
#
# No hardened runtime and no notarisation: the bundle is built and installed on the
# same machine, never quarantined, and the runtime would need the Bluetooth entitlement.
# The mini keeps the identity in a dedicated keychain that a reboot leaves locked; it is
# unlocked from a 0600 password file outside the repo when both exist (dotfiles
# docs/apple-signing.md, "Developer ID in a dedicated keychain").
SIGNING_KEYCHAIN=${SIGNING_KEYCHAIN:-$HOME/Library/Keychains/iris-signing.keychain-db}
SIGNING_KEYCHAIN_PASS_FILE=${SIGNING_KEYCHAIN_PASS_FILE:-$HOME/.local/state/apple-developer/signing-keychain.pass}

unlock_signing_keychain() {
  [[ -r "$SIGNING_KEYCHAIN_PASS_FILE" && -e "$SIGNING_KEYCHAIN" ]] || return 0
  security unlock-keychain -p "$(cat "$SIGNING_KEYCHAIN_PASS_FILE")" "$SIGNING_KEYCHAIN" 2>/dev/null ||
    echo "warning: could not unlock $SIGNING_KEYCHAIN" >&2
}

# Prints the SHA-1 of the first "Developer ID Application" identity (team-filtered when
# APPLE_TEAM_ID is set), nothing when there is none.
find_developer_id() {
  unlock_signing_keychain
  security find-identity -v -p codesigning 2>/dev/null |
    awk -v team="(${APPLE_TEAM_ID:-})" '/Developer ID Application:/ && (team == "()" || index($0, team)) { print $2; exit }'
}

sign_adhoc() {
  codesign --force --deep --sign - "$APP_PATH"
}

sign_identity() {
  codesign --force --sign "$1" "$APP_PATH"
}

SIGN_IDENTITY=${SIGN_IDENTITY:-}
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  SIGN_MODE=ad-hoc
  sign_adhoc
elif [[ -n "$SIGN_IDENTITY" ]]; then
  SIGN_MODE=identity
  sign_identity "$SIGN_IDENTITY"
else
  SIGN_ID=$(find_developer_id)
  if [[ -n "$SIGN_ID" ]] && sign_identity "$SIGN_ID"; then
    SIGN_MODE=developer-id
  else
    echo "warning: no usable Developer ID Application identity; signing ad-hoc." >&2
    echo "warning: every rebuild now gets a new code requirement and macOS asks for Bluetooth again." >&2
    SIGN_MODE=ad-hoc
    sign_adhoc
  fi
fi
codesign --verify --strict "$APP_PATH"
SIGN_REQUIREMENT=$(codesign -d -r- "$APP_PATH" 2>&1 | sed -n 's/^#* *designated => //p')

# Touch the bundle so Launch Services notices the change next time it's opened.
touch "$APP_PATH"

echo "wrote $APP_PATH (v$VERSION, signed: $SIGN_MODE)"
echo "designated requirement: $SIGN_REQUIREMENT"
