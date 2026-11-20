#!/usr/bin/env bash
# Refuse to restart the daemon while the belt is moving.
#
# A restart drops the BLE link and the in-flight session, so a deploy must not
# land in the middle of a walk. Reads GET /status and refuses when belt_state is
# anything but stopped or standby (active, starting, stopping, unknown).
# A pad that is not connected carries no belt_state; if a session is still open
# then (the link dropped mid-walk), that refuses too.
# Fails open: an unanswered /status proceeds; any non-2xx answer (401/403 when the
# daemon has an http_token and KSWP_HTTP_TOKEN is not exported here) proceeds with
# a warning that the belt state was not checked.
#
# Usage:  FORCE=1 scripts/deploy-guard.sh [<status-url>]
# Reads only. Sends nothing to the belt.

set -uo pipefail

URL=${1:-${WALKINGPAD_STATUS_URL:-http://127.0.0.1:7706/status}}

if [[ ${FORCE:-} == 1 ]]; then
  echo "deploy guard: FORCE=1, skipping the belt-state check"
  exit 0
fi

CURL=${CURL:-curl}
auth=()
[[ -n ${KSWP_HTTP_TOKEN:-} ]] && auth=(-H "Authorization: Bearer $KSWP_HTTP_TOKEN")

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
code=$("$CURL" -sS --max-time 3 ${auth[@]+"${auth[@]}"} -o "$TMP" -w '%{http_code}' "$URL" 2>/dev/null) || code=""

case "$code" in
  2?? | 000) ;; # 000: a file:// URL in the test; parse the body below
  "")
    echo "deploy guard: /status does not answer, proceeding"
    exit 0
    ;;
  *)
    echo "deploy guard: WARNING — /status answered $code; belt state NOT checked. Proceeding." >&2
    [[ $code == 401 || $code == 403 ]] && echo "deploy guard: http_token set? export KSWP_HTTP_TOKEN to enable the check." >&2
    exit 0
    ;;
esac

body=$(cat "$TMP")
state=$(printf '%s' "$body" | sed -n 's/.*"belt_state":"\([^"]*\)".*/\1/p')

if [[ -z $state && $body != *'"current_session":null'* && $body == *'"current_session":{'* ]]; then
  echo "deploy guard: REFUSED — the pad is not connected but a session is still open." >&2
  echo "deploy guard: wait for it to close, or run with FORCE=1 to override." >&2
  exit 1
fi

case "$state" in
  "" | stopped | standby)
    echo "deploy guard: belt state ${state:-n/a}, safe to restart"
    ;;
  *)
    echo "deploy guard: REFUSED — belt state is \"$state\"; a restart would cut the session." >&2
    echo "deploy guard: stop the belt first, or run with FORCE=1 to override." >&2
    exit 1
    ;;
esac
