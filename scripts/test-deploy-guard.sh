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
expect "proceeds when the pad is not connected and no session is open" 0 - "" "file://$TMP/disconnected.json"
echo '{"connected":false,"current_session":{"uuid":"x","samples":[]}}' >"$TMP/orphan.json"
expect "refuses when the pad dropped with a session open" 1 "session is still open" "" "file://$TMP/orphan.json"

# 401 (daemon has an http_token): loud warning on stderr, deploy proceeds.
# Any other non-2xx answer (404, 500) warns the same way, never "safe to restart".
for c in 401 404 500; do
  printf '#!/usr/bin/env bash\nprintf %s %s\n' '%s' "$c" >"$TMP/curl$c"
  chmod +x "$TMP/curl$c"
  out=$(CURL="$TMP/curl$c" "$GUARD" http://127.0.0.1:7706/status 2>&1 >/dev/null); rc=$?
  if [[ $rc -eq 0 && $out == *"WARNING"* && $out == *"$c"* ]]; then echo "ok   warns and proceeds on $c"; else echo "FAIL $c: exit $rc, stderr: $out"; fail=1; fi
done
expect "proceeds when /status is unreachable" 0 "does not answer" "" "http://127.0.0.1:1/status"
expect "proceeds on a body that is not JSON" 0 - "" "$(printf 'x' >"$TMP/junk" && echo "file://$TMP/junk")"

exit $fail
