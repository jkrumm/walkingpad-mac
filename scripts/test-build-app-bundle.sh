#!/usr/bin/env bash
# Test scripts/build-app-bundle.sh signing: ad-hoc builds work everywhere; where the
# machine holds a Developer ID identity, two different builds must share one designated
# requirement (that is what keeps the Bluetooth TCC grant across a deploy).
#
# Usage:  scripts/test-build-app-bundle.sh

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/scripts/build-app-bundle.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1" >&2; fails=$((fails + 1)); }

# A distinct Mach-O per build (the exit code differs), so the cdhash differs between builds.
make_binary() { # <path> <exit code>
  printf 'int main(void){return %s;}' "$2" >"$1.c"
  cc -o "$1" "$1.c"
}

requirement() { codesign -d -r- "$1" 2>&1 | sed -n 's/^#* *designated => //p'; }

make_binary "$TMP/a" 1
make_binary "$TMP/b" 2

# Ad-hoc, forced: signs, verifies, and the requirement is the cdhash (differs per build).
SIGN_IDENTITY=- "$SCRIPT" "$TMP/a" 1.0.0 "$TMP/a.app" >"$TMP/a.out" 2>&1 && ok "ad-hoc build succeeds" || bad "ad-hoc build succeeds: $(cat "$TMP/a.out")"
SIGN_IDENTITY=- "$SCRIPT" "$TMP/b" 1.0.0 "$TMP/b.app" >"$TMP/b.out" 2>&1 || bad "second ad-hoc build succeeds"
grep -q 'signed: ad-hoc' "$TMP/a.out" && ok "ad-hoc mode is reported" || bad "ad-hoc mode is reported"
[[ "$(requirement "$TMP/a.app")" != "$(requirement "$TMP/b.app")" ]] && ok "ad-hoc requirement changes per build" || bad "ad-hoc requirement changes per build"

# Unset identity on a machine without a Developer ID certificate falls back to ad-hoc with a warning.
# Where one exists, two different builds must carry the same Developer ID requirement.
if security find-identity -v -p codesigning 2>/dev/null | grep -q 'Developer ID Application:'; then
  "$SCRIPT" "$TMP/a" 1.0.0 "$TMP/a.app" >"$TMP/a.out" 2>&1 || bad "Developer ID build succeeds: $(cat "$TMP/a.out")"
  "$SCRIPT" "$TMP/b" 1.0.1 "$TMP/b.app" >"$TMP/b.out" 2>&1 || bad "second Developer ID build succeeds: $(cat "$TMP/b.out")"
  grep -q 'signed: developer-id' "$TMP/a.out" && ok "Developer ID mode is reported" || bad "Developer ID mode is reported: $(cat "$TMP/a.out")"
  ra=$(requirement "$TMP/a.app")
  [[ -n "$ra" && "$ra" == "$(requirement "$TMP/b.app")" ]] && ok "Developer ID requirement is identical across builds" || bad "Developer ID requirement is identical across builds"
  [[ "$ra" == *'identifier "com.jkrumm.walkingpad"'* && "$ra" != *cdhash* ]] && ok "requirement is the bundle id plus the certificate, no cdhash" || bad "requirement shape: $ra"
  # copying the installed bundle (make deploy does cp -R) keeps the signature
  cp -R "$TMP/a.app" "$TMP/copy.app"
  [[ "$(requirement "$TMP/copy.app")" == "$ra" ]] && codesign --verify --strict "$TMP/copy.app" && ok "cp -R keeps the signature" || bad "cp -R keeps the signature"
else
  echo "skip Developer ID checks: no identity in the keychain search list"
fi

# An explicit identity that does not exist is fatal, not a silent ad-hoc.
SIGN_IDENTITY=no-such-identity "$SCRIPT" "$TMP/a" 1.0.0 "$TMP/c.app" >"$TMP/c.out" 2>&1 && bad "unknown SIGN_IDENTITY is refused" || ok "unknown SIGN_IDENTITY is refused"

exit $((fails > 0))
