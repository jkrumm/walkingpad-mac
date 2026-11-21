#!/usr/bin/env bash
# Tests scripts/install-macbook.sh without a MacBook: the dry run prints the command the owner is shown, a stub stands in
# for ask-human.sh. Checks the command parses, fits the dialog, carries the version and URL, hands the token over on
# stdin only, and that a missing or malformed URL refuses.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$root/scripts/install-macbook.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

passed=0
failed=0
ok() { passed=$((passed + 1)); echo "ok   $1"; }
bad() { failed=$((failed + 1)); echo "FAIL $1" >&2; }
check() { # description, command...
  local what="$1"
  shift
  if "$@"; then ok "$what"; else bad "$what"; fi
}

app="$tmp/WalkingPad.app"
mkdir -p "$app/Contents"
plutil -create xml1 "$app/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string 'abc1234' "$app/Contents/Info.plist"
app="$(cd "$app" && pwd -P)" # the installer resolves symlinks (/var is /private/var)

stub="$tmp/ask-human.sh"
cat >"$stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_ARGS"
echo "test-request-id"
STUB
chmod +x "$stub"

url="https://door.example.com"
cmd="$(WALKINGPAD_HOST_URL="$url" INSTALL_DRY_RUN=1 "$installer" "$app")"

check "the command parses" bash -n <<<"$cmd"
check "the command is one line" test "$(wc -l <<<"$cmd")" -eq 1
check "the command fits the dialog (2500 characters)" test "${#cmd}" -lt 2500
check "the command pulls the bundle from the mini" grep -q "rsync -a --delete .* mini:'$app'/" <<<"$cmd"
check "the command writes the host URL" grep -q "hostURL '$url'" <<<"$cmd"
check "the command compares the built version" grep -q "'abc1234'" <<<"$cmd"
check "the command requires Notarized Developer ID" grep -q "Notarized Developer ID" <<<"$cmd"
check "the token reaches security on stdin (printf | security -i)" grep -q "printf 'add-generic-password .* -w %s.*| security -i" <<<"$cmd"
check "the token is never an argument of security" bash -c '! grep -Eq "security (add|-w)[^|]*-w [^%]" <<<"$1"' _ "$cmd"
check "no 64-character secret in the command" bash -c '! grep -Eq "[0-9a-f]{64}" <<<"$1"' _ "$cmd"
check "the keychain item is trusted for the app" grep -q -- "-T %s" <<<"$cmd"

args="$tmp/args"
STUB_ARGS="$args" ASK_HUMAN="$stub" WALKINGPAD_HOST_URL="$url" XDG_STATE_HOME="$tmp/state" "$installer" "$app" >"$tmp/out" 2>&1 || true
check "ask-human gets the command after --cmd" grep -qxF -- "$cmd" "$args"
check "ask-human gets a key, so a newer request replaces an older one" grep -qx -- "--key" "$args"
check "the dialog text carries the build and no token" bash -c '! grep -Eq "[0-9a-f]{40,}" "$1" && grep -q "build abc1234" "$1"' _ "$args"

if WALKINGPAD_HOST_URL="http://door.example.com" INSTALL_DRY_RUN=1 "$installer" "$app" >/dev/null 2>&1; then bad "a plain http URL is refused"; else ok "a plain http URL is refused"; fi
if WALKINGPAD_HOST_URL="https://x.example.com/'; id; '" INSTALL_DRY_RUN=1 "$installer" "$app" >/dev/null 2>&1; then bad "a URL with a quote is refused"; else ok "a URL with a quote is refused"; fi
if HOME="$tmp/empty-home" WALKINGPAD_HOST_URL="" INSTALL_DRY_RUN=1 "$installer" "$app" >/dev/null 2>&1; then bad "no URL is refused"; else ok "no URL is refused"; fi
if WALKINGPAD_HOST_URL="$url" INSTALL_DRY_RUN=1 "$installer" "$tmp/missing.app" >/dev/null 2>&1; then bad "a missing bundle is refused"; else ok "a missing bundle is refused"; fi

echo "$passed passed, $failed failed"
[[ "$failed" == 0 ]]
