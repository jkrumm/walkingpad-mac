#!/usr/bin/env bash
# Table test for scripts/deploy-guard.sh. The /status answer is a file:// URL
# (curl reads it like an HTTP body), so no server and no belt is involved.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GUARD="$SCRIPT_DIR/deploy-guard.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0

# expect <name> <want-exit> <want-stderr-substring|-> <force> <url>
expect() {
  local name=$1 want=$2 needle=$3 force=$4 url=$5 out rc
  out=$(FORCE="$force" "$GUARD" "$url" 2>&1)
  rc=$?
  if [[ $rc -ne $want ]] || { [[ $needle != - ]] && [[ $out != *"$needle"* ]]; }; then
    echo "FAIL $name: exit $rc (want $want), output: $out"
    fail=1
  else
    echo "ok   $name"
  fi
}

status_file() { # <belt_state>
  printf '{"connected":true,"belt_state":"%s","speed_kmh":3,"current_session":null}' "$1" >"$TMP/$1.json"
  echo "file://$TMP/$1.json"
}

for state in active starting stopping "unknown(3)"; do
  expect "refuses $state" 1 "\"$state\"" "" "$(status_file "$state")"
done
for state in stopped standby; do
  expect "allows $state" 0 - "" "$(status_file "$state")"
done

expect "FORCE=1 overrides an active belt" 0 FORCE=1 1 "$(status_file active)"

echo '{"connected":false,"current_session":null}' >"$TMP/disconnected.json"
expect "proceeds when the pad is not connected" 0 - "" "file://$TMP/disconnected.json"
expect "proceeds when /status is unreachable" 0 "does not answer" "" "http://127.0.0.1:1/status"
expect "proceeds on a body that is not JSON" 0 - "" "$(printf 'x' >"$TMP/junk" && echo "file://$TMP/junk")"

exit $fail
