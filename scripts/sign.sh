#!/usr/bin/env bash
# Developer ID signing, notarization and stapling of the built WalkingPad.app. Usage: scripts/sign.sh <path-to-app>
#
#   NOTARIZE=1  (default) submit to Apple, wait, staple. NOTARY_TIMEOUT bounds the wait (default 40m; a first
#               submission can queue for hours). When it runs out or Apple answers Invalid, the script prints the
#               submission id; RESUME_NOTARY_ID=<id> waits on that submission without re-signing or re-submitting
#               (a changed byte would void it), then staples.
#   NOTARIZE=0  sign and verify only (--developer-id), nothing leaves the machine.
#
# The team id and the App Store Connect key come from APPLE_TEAM_ID, ASC_KEY_P8, ASC_KEY_ID, ASC_ISSUER_ID or, on the
# mini, secrets-run (scripts/apple-credentials.sh). The app has no entitlements and no sandbox: Hardened Runtime with a
# secure timestamp is all notarization asks. Everything nested is signed inside out, never with --deep. Every run ends in
# scripts/verify-signature.sh; a failed verification is a non-zero exit.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${1:?usage: sign.sh <path-to-app>}"
notarize="${NOTARIZE:-1}"
resume_id="${RESUME_NOTARY_ID:-}"

fail() {
  echo "sign: $*" >&2
  exit 1
}

[[ -d "$app" ]] || fail "no app at $app"
[[ "$notarize" == 0 || "$notarize" == 1 ]] || fail "NOTARIZE must be 0 or 1"
[[ -z "$resume_id" || "$notarize" == 1 ]] || fail "RESUME_NOTARY_ID needs NOTARIZE=1"

# shellcheck source=scripts/apple-credentials.sh
. "$root/scripts/apple-credentials.sh"
ASC_KEY_FILE=""
work="$(mktemp -d)"
trap 'rm -rf "$work"; [[ -z "$ASC_KEY_FILE" ]] || rm -f "$ASC_KEY_FILE"' EXIT

load_team || fail "no team id"
unlock_signing_keychain || fail "cannot unlock the signing keychain"
resolve_developer_id || fail "no signing identity"
command -v jq >/dev/null || fail "jq is required"

sign_one() { # path
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$1" 2>&1 | redact >&2 || fail "codesign failed for $1"
}

# Inside out: nested frameworks, XPC services, helpers and dylibs (find -depth lists children first), the app last.
sign_bundle() {
  local item
  while IFS= read -r item; do
    sign_one "$item"
  done < <(find "$app/Contents" -depth \( -name '*.framework' -o -name '*.xpc' -o -name '*.dylib' -o -name '*.app' \))
  sign_one "$app"
}

if [[ -z "$resume_id" ]]; then
  sign_bundle
  "$root/scripts/verify-signature.sh" "$app" --developer-id
fi
[[ "$notarize" == 1 ]] || exit 0

load_notary_credentials || fail "no App Store Connect key"
notary=(xcrun notarytool)
auth=(--key "$ASC_KEY_FILE" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
timeout="${NOTARY_TIMEOUT:-40m}"

# A wait exits 0 on an Invalid verdict, so the status is read from the JSON.
if [[ -n "$resume_id" ]]; then
  result="$("${notary[@]}" wait "$resume_id" "${auth[@]}" --timeout "$timeout" --output-format json || true)"
else
  ditto -c -k --sequesterRsrc --keepParent "$app" "$work/notarize.zip"
  result="$("${notary[@]}" submit "$work/notarize.zip" "${auth[@]}" --wait --timeout "$timeout" --output-format json || true)"
fi
submission="${resume_id:-$(jq -r '.id // empty' <<<"$result" 2>/dev/null || true)}"
status="$(jq -r '.status // empty' <<<"$result" 2>/dev/null || true)"
echo "notarytool: id=${submission:-unknown} status=${status:-unknown}"
if [[ "$status" != "Accepted" ]]; then
  if [[ -n "$submission" ]]; then
    "${notary[@]}" log "$submission" "${auth[@]}" 2>&1 | redact >&2 || true
    echo "to continue without re-signing: RESUME_NOTARY_ID=$submission NOTARIZE=1 scripts/sign.sh $app" >&2
  fi
  fail "notarization was not accepted (status: ${status:-none})"
fi

# The ticket can take a moment to reach the CDN after Accepted.
stapled=0
for attempt in 1 2 3 4 5; do
  if xcrun stapler staple "$app" >/dev/null 2>&1; then
    stapled=1
    break
  fi
  echo "stapler: ticket not available yet (attempt $attempt)" >&2
  sleep 10
done
[[ "$stapled" == 1 ]] || fail "could not staple the ticket"
"$root/scripts/verify-signature.sh" "$app" --release
