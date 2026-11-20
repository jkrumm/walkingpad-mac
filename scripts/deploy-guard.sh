#!/usr/bin/env bash
# Refuse to restart the daemon while the belt is moving.
#
# A restart drops the BLE link and the in-flight session, so a deploy must not
# land in the middle of a walk. Reads GET /status and refuses when belt_state is
# anything but stopped or standby (active, starting, stopping, unknown).
# Fails open: when /status does not answer, or carries no belt_state (the pad is
# not connected, so nothing is moving), the deploy proceeds.
#
# Usage:  FORCE=1 scripts/deploy-guard.sh [<status-url>]
# Reads only. Sends nothing to the belt.

set -uo pipefail

URL=${1:-${WALKINGPAD_STATUS_URL:-http://127.0.0.1:7706/status}}

if [[ ${FORCE:-} == 1 ]]; then
  echo "deploy guard: FORCE=1, skipping the belt-state check"
  exit 0
fi

body=$(curl -fsS --max-time 3 "$URL" 2>/dev/null) || {
  echo "deploy guard: /status does not answer, proceeding"
  exit 0
}

state=$(printf '%s' "$body" | sed -n 's/.*"belt_state":"\([^"]*\)".*/\1/p')

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
