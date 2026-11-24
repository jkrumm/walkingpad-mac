# AGENTS.md — apple/ (Swift menu bar client)

Loaded when a file under `apple/` is read. Paths are from the repo root. Parent: `AGENTS.md`.

- The app is a client of the host's HTTP API and owns no Bluetooth and no database. A response
  shape changes in Go first: edit `internal/api/types.go`, run `make contracts`, commit the
  fixtures, then make PadKit's models decode them. Never hand-write a shape a fixture defines; a
  new fixture also needs its model in `ContractTests.shapes`, or `swift test` fails.
- Never send `POST /start`, `/stop`, `/speed` or `/pref/*` to the live host from a test or a
  proof: the belt is a physical machine with a person on it. GETs against `http://127.0.0.1:7706`
  are fine (`make test-live`).
- Every `xcodebuild` goes through `scripts/apple-slot.sh`. Edit `apple/project.yml`, never the
  generated project. Swift 6 language mode with complete concurrency checking; warnings are errors in
  the app and in PadKit. swift-format owns layout (`.swift-format`), SwiftLint `--strict` owns the
  rest (`.swiftlint.yml`); tools are pinned with checksums in `scripts/tools.sh`.
- The app's bundle id is `com.jkrumm.walkingpad.client`; `com.jkrumm.walkingpad` is the host daemon,
  whose Bluetooth grant is tied to that id.
- History (`HistoryStore` in PadKit, `HistoryView`) only issues GETs. A day is the host's local calendar day and a
  walk counts on the day it started (`GET /summary/days`, `docs/protocol.md` section 8).
- `PadStore` (PadKit) is the one source of truth: it polls `GET /status` (`PollingPolicy`: 1 s while the
  belt moves, a session is open or the popover shows, 10 s otherwise, never without a host), maps every
  answer to one `PadPhase` and sends the commands. Views and hotkeys only read it and call it; behaviour
  goes into PadKit with a test, the app target has none. Speed changes only while `active`, and a queued
  speed goes out only after a fresh `/status` still reads active: the host starts a stopped belt on
  `/speed`. Stop is held while a speed is in flight for the same reason.
- Settings is a `Window` scene, never the `Settings` scene (an accessory app cannot bring it forward).
  The host URL and start speed live in UserDefaults (`-hostURL <url>` overrides the URL for one run),
  the token in the Keychain. Hotkeys are KeyboardShortcuts, pinned exactly in `apple/project.yml`.
- Launch at login is never a disabled toggle: `SMAppService.mainApp` reports `notFound` for an app that has not
  registered yet, so the toggle always tries `register()` and shows the result or the error (`LoginItemState` in PadKit).
- KeyboardShortcuts writes a Name's `initial:` shortcut into UserDefaults on first read, so changing a default reaches no
  existing install: `HotkeyDefaults.migrate` (rule and tests: PadKit `HotkeyMigration`, bump `version` with a default change) moves a stored shortcut that still equals a previous default, once. It drops a
  failed Carbon registration silently; Settings reads `KeyboardShortcuts.isEnabled(for:)` to warn (the snapshot build runs no
  listener and skips it). The menu bar title's values are `MenuBarValues` (PadKit, UserDefaults `menuBarValues`).
- The app icon is `apple/branding/AppIcon.icns` split into `apple/WalkingPad/Assets.xcassets/AppIcon.appiconset`
  (`iconutil -c iconset`); never redraw the mark.
- **Release and install:** `make app-release` signs (Developer ID), notarizes and staples the app, `make install-macbook`
  pulls it onto the MacBook. `app-release` holds the Apple lock and notarization can queue for hours: read `docs/app-install.md` before
  running either, and run `app-release` in the background with its exit code in a log.
- `make snapshots` builds the app with `SNAPSHOT_HARNESS` (own derived data `apple/.dd-snap`) and draws
  the popover in every `PadPhase`, Settings and the History window (`history-*`), light and dark, offscreen
  against an in-memory host into `apple/.snapshots/` (`SNAP_DIR` overrides). `SNAP_LIVE_URL=http://127.0.0.1:7706`
  adds `popover-live-*` and `history-live-*` from the running host (GET only) and prints its state;
  `SNAP_LIVE_NOW=YYYY-MM-DD` sets History's "today" when the host's walks are old. Temp HOME, no Keychain,
  no login item, no network otherwise. Look at the PNGs after a UI change; there is no golden file.
  Prominent buttons and toggles draw greyed: an offscreen window of an accessory app is never active.
