# Release build and MacBook install of the menu bar app

How `make app-release`, `make verify-app` and `make install-macbook` work, and why. Row: `app-install` in `docs/plan.yaml`.

`make app-release` builds Release (`apple/.dd-release`, arm64, `MARKETING_VERSION` is the
`scripts/build-version.sh` sha, `CURRENT_PROJECT_VERSION` the commit count), copies it to
`~/.local/state/walkingpad/client/WalkingPad.app` and runs `scripts/sign.sh`: Developer ID, Hardened Runtime, secure
timestamp, no entitlements, notarization and stapling, then `scripts/verify-signature.sh --release` (`make verify-app`).
`NOTARIZE=0` signs only. Credentials come from `secrets-run read op://mini/apple-developer/<field>` through
`scripts/apple-credentials.sh`; the team id is in no file and no log (`redact`). The xcodebuild and the notarization
both run in `scripts/apple-slot.sh`, so a notarization holds the Apple lock for up to `NOTARY_TIMEOUT` (40m; a first
submission can queue for hours): run it in the background with its exit code in a log. On a timeout or an Invalid verdict
the script prints the submission id; `RESUME_NOTARY_ID=<id> NOTARIZE=1 scripts/sign.sh <app>` continues without re-signing.
`make install-macbook` pulls that bundle to `~/Applications/WalkingPad.app` on the MacBook through one ask-human dialog:
rsync from the mini, signature, staple, Gatekeeper and version checks, host URL into UserDefaults, the remote token
(`walkingpad token`) into the login Keychain with the app trusted, relaunch. The token travels ssh stdout to a shell variable
to `security -i` stdin: never in the dialog, argv, output or a file. The door URL is in no tracked file: it is read from
`WALKINGPAD_HOST_URL` or `~/.local/state/walkingpad/door-url`. The keychain unlock and the Developer ID lookup in `scripts/apple-credentials.sh` are deliberately separate from `scripts/build-app-bundle.sh` (the daemon bundle falls back to ad-hoc, a release must fail closed). Test: `scripts/test-install-macbook.sh`. Never send a belt
command to prove an install; the owner does the first live start.
