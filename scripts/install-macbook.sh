#!/usr/bin/env bash
# Installs the built WalkingPad.app on the MacBook by pulling, not pushing: the mini's `iumac` key runs a fixed verb
# list only (no rsync, no arbitrary commands), so the one MacBook-side command goes through ask-human.sh, which
# shows it in a native dialog on the MacBook and runs it on the owner's click. One dialog does the whole install.
#
# Usage: scripts/install-macbook.sh <path to the built WalkingPad.app on this machine>
# The MacBook rsyncs the bundle from the mini (`ssh mini`) into ~/Applications/WalkingPad.app, verifies the signature,
# the staple and Gatekeeper, checks that the bundle's version is the one built here, quits the running copy, writes the
# host URL into the app's preferences, stores the remote token in the login Keychain and opens the app.
#
# The token never appears in the dialog, in argv, in the command's output or in a file: the MacBook reads it from
# `ssh mini walkingpad token` into a shell variable and hands it to `security -i` on stdin (printf is a builtin, so no
# process ever carries it in argv). The item is created with the app trusted (-T), so the app reads it without a prompt.
#
# The host URL (the mini's tailnet door in front of the remote listener) is in no tracked file: WALKINGPAD_HOST_URL, else
# the first line of ~/.local/state/walkingpad/door-url on this machine.
# INSTALL_DRY_RUN=1 prints the MacBook command and exits (scripts/test-install-macbook.sh).
set -euo pipefail

fail() {
  echo "install-macbook: $*" >&2
  exit 1
}

app="${1:?usage: install-macbook.sh <WalkingPad.app>}"
[[ -d "$app" ]] || fail "no app bundle at $app (run make app-release)"
app="$(cd "$app" && pwd -P)"

mini_host="${MINI_HOST:-mini}"
daemon='/Applications/WalkingPad.app/Contents/MacOS/walkingpad'
lsregister='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'

host_url="${WALKINGPAD_HOST_URL:-}"
[[ -n "$host_url" ]] || host_url="$(head -n 1 "${HOME}/.local/state/walkingpad/door-url" 2>/dev/null || true)"
[[ -n "$host_url" ]] || fail "no host URL: set WALKINGPAD_HOST_URL or write the door URL into ~/.local/state/walkingpad/door-url"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"

# Everything below goes between single quotes on the MacBook.
safe='^[A-Za-z0-9._:/-]+$'
[[ "$host_url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] || fail "the host URL must be a plain https URL"
[[ "$version" =~ $safe ]] || fail "unexpected version string"
[[ "$app" =~ $safe && "$mini_host" =~ $safe ]] || fail "unexpected characters in the app path or the mini host"

# Runs on the MacBook; one statement per line, joined with '; ' below. Output stays short (the result keeps the last
# 2000 characters) and carries no secret: the Keychain step is silent and verified by a lookup without -w.
read -r -d '' template <<'MACBOOK' || true
set -e
dest="$HOME/Applications/WalkingPad.app"
mkdir -p "$HOME/Applications"
rsync -a --delete -e 'ssh -o BatchMode=yes' @MINI@:'@APP@'/ "$dest"/
@LSREGISTER@ -f "$dest"
codesign --verify --deep --strict "$dest" && echo 'codesign: valid'
xcrun stapler validate "$dest" >/dev/null && echo 'stapled: yes'
a=$(spctl --assess --type execute --verbose=4 "$dest" 2>&1) || { echo 'spctl: rejected'; exit 1; }
echo "$a" | grep -q '^source=Notarized Developer ID$' && echo 'spctl: accepted, Notarized Developer ID' || { echo 'spctl: not notarized'; exit 1; }
v=$(defaults read "$dest/Contents/Info" CFBundleShortVersionString)
[ "$v" = '@VERSION@' ] && echo "version: $v is the build" || { echo "version: $v, built @VERSION@"; exit 1; }
pkill -x WalkingPad || true
sleep 1
defaults write com.jkrumm.walkingpad.client hostURL '@URL@'
t=$(ssh -o BatchMode=yes @MINI@ '@DAEMON@ token')
[ -n "$t" ] || { echo 'token: the mini returned none'; exit 1; }
security delete-generic-password -s com.jkrumm.walkingpad.client -a host-token >/dev/null 2>&1 || true
printf 'add-generic-password -s com.jkrumm.walkingpad.client -a host-token -T %s -w %s\n' "$dest" "$t" | security -i >/dev/null 2>&1
unset t
security find-generic-password -s com.jkrumm.walkingpad.client -a host-token >/dev/null && echo 'token: stored in the login Keychain' || { echo 'token: not stored'; exit 1; }
open "$dest" && echo 'relaunched: ~/Applications/WalkingPad.app'
MACBOOK

cmd="$template"
cmd="${cmd//@MINI@/$mini_host}"
cmd="${cmd//@APP@/$app}"
cmd="${cmd//@LSREGISTER@/$lsregister}"
cmd="${cmd//@VERSION@/$version}"
cmd="${cmd//@URL@/$host_url}"
cmd="${cmd//@DAEMON@/$daemon}"
cmd="$(printf '%s' "$cmd" | paste -sd ';' - | sed 's/;/; /g')"

if [[ "${INSTALL_DRY_RUN:-0}" == 1 ]]; then
  printf '%s\n' "$cmd"
  exit 0
fi

ask_human="${ASK_HUMAN:-$HOME/SourceRoot/dotfiles/scripts/ask-human.sh}"
[[ -x "$ask_human" ]] || fail "ask-human.sh not found at $ask_human"

set +e
id="$("$ask_human" ask "Install WalkingPad.app (build $version) from ${mini_host} into ~/Applications, connect it to the host and relaunch it" \
  --key walkingpad-install-macbook --cmd "$cmd" | head -n 1)"
rc=${PIPESTATUS[0]}
set -e

res="${XDG_STATE_HOME:-$HOME/.local/state}/human-queue/${id}.res"
if [[ -f "$res" ]]; then
  echo "MacBook result (request $id, exit $rc):"
  # output_tail is one JSON string; unescape the newlines for reading.
  sed -nE 's/.*"output_tail":"(.*)"\}?$/\1/p' "$res" | sed 's/\\n/\n/g; s/\\"/"/g'
else
  echo "no MacBook result for request $id (exit $rc): the dialog is still pending or the MacBook is unreachable" >&2
fi
exit "$rc"
