# AGENTS.md — walkingpad-mac

> **Naming.** The repo and Go module are `walkingpad-mac`; the entrypoint is
> `cmd/walkingpad/`. Everything user-facing is `WalkingPad` (display) /
> `walkingpad` (CLI binary, identifier, log paths). The compiled output is
> `bin/walkingpad`, installed to `/Applications/WalkingPad.app/Contents/MacOS/walkingpad`.
>
> **Where this is going.** The Go daemon stays the host; a Swift menu bar app under
> `apple/` becomes its client. Design: `docs/spec.md`. Rows: `docs/plan.yaml`.
> How the factory ships the repo: `project.yaml`.

Per-project guidance for coding agents. The global config (`~/.claude/CLAUDE.md` for Claude Code) applies; this file adds project-specific rules.

## What this project is

A macOS LaunchAgent (Go) + Raycast extension that controls and tracks the KingSmith **WalkingPad P1** treadmill over BLE. Local SQLite is the source of truth; completed sessions sync to the personal **Argo** API. No Garmin integration (deliberate non-goal — see README's Why section). License **AGPL-3.0**.

**Read [`README.md`](./README.md) and [`docs/protocol.md`](docs/protocol.md) first.** The
README covers architecture and the API contract; `docs/protocol.md` is the source of truth
for the BLE protocol, schema and session-grouping logic. This file is the operator's manual
for agents.

## Stack

| Layer | Choice | Why |
|-|-|-|
| Daemon language | **Go 1.26+** | Single binary, easy LaunchAgent, native macOS Bluetooth via cgo |
| BLE library | **`tinygo.org/x/bluetooth` v0.16.0** | Only cross-platform Go BLE lib; P1 verified on v0.10.0, not yet on v0.16.0 |
| SQLite driver | **`modernc.org/sqlite`** | Pure Go (no CGO) — keeps cross-compile easy |
| HTTP | **stdlib `net/http`** | Loopback only, no framework needed |
| Logging | **`log/slog`** → JSONL on disk + pretty on stderr | Standard library, structured |
| Config | **TOML** via `github.com/BurntSushi/toml` | Human-editable |
| Raycast extension | **TypeScript** with `@raycast/api` + `@raycast/utils` | Standard Raycast stack |

## Validate

| Tier | Runs | Who |
|-|-|-|
| `make check-fast` | gofmt, vet, golangci-lint, `go test -race`, raycast `tsc`, `swift format lint`, SwiftLint, `swift test` of PadKit; no xcodebuild | a lead, before every push |
| `make check` | check-fast plus `make check-apple` (xcodegen, xcodebuild of the app through `scripts/apple-slot.sh`) | CI (`.github/workflows/ci.yml`, hosted macOS) on every push and PR |

`project.yaml` `checks` names the tiers. Run `make check-apple` locally only when you changed
`apple/project.yml` or app code: it takes the mini's one Apple lock, shared with iris and ntfy-mac.
`make fmt` fixes Go and Swift formatting; `make contracts` rewrites the API fixtures. lefthook
(`brew install lefthook && lefthook install`) runs the Go checks and `swift format lint` on staged files.

## Deploy

`make up` is the one command after every code change: it rebuilds the daemon,
swaps `/Applications/WalkingPad.app`, kickstarts the LaunchAgent, prints the
live `/health` version, then starts the Raycast dev loop. `make deploy` runs
just the ship/restart half — build, install the `.app`, kickstart the agent —
with no Raycast dev loop and no commands sent to the belt.

- **Guard.** `make deploy`/`rollback` read `GET /status` first and refuse unless
  `belt_state` is `stopped`/`standby`, and when the pad dropped with a session open: a
  restart cuts the walk. `FORCE=1` overrides. No answer proceeds; any non-2xx (401 with an
  `http_token`: export `KSWP_HTTP_TOKEN`) proceeds with a warning. Test: `scripts/test-deploy-guard.sh`.
- **Rollback.** `make deploy` keeps the bundle it replaces in
  `~/.local/state/walkingpad/rollback/`; `make rollback` reinstalls it. The old bundle
  keeps its signature, so its Bluetooth permission returns with it.
- **Signing.** `scripts/build-app-bundle.sh` signs with the team's Developer ID Application
  identity when the keychain search list holds one (the mini unlocks `iris-signing.keychain-db` from
  its password file, dotfiles `docs/apple-signing.md`), else ad-hoc with a warning. macOS keeps the
  Bluetooth grant against the designated requirement: Developer ID's is the bundle id plus the team,
  identical on every build; ad-hoc's is the cdhash, so each rebuild re-prompts on the mini display and
  BLE times out until someone clicks Allow. `SIGN_IDENTITY=-` forces ad-hoc. With `SIGN_IDENTITY=<id>` a signing
  failure aborts the build; unset, a failed Developer ID signature (a locked keychain) falls back to
  ad-hoc with a warning, so read the deploy output for `signed: developer-id`. The daemon bundle has no hardened runtime and no
  notarisation (local build, never quarantined; the Swift app's Developer ID release is separate). Test: `scripts/test-build-app-bundle.sh`. The first
  deploy that switches from ad-hoc to Developer ID prompts once.
- **Version.** `scripts/build-version.sh` stamps the sha; the why is in its header.

The LaunchAgent label is `com.jkrumm.walkingpad`, installed at
`~/Library/LaunchAgents/com.jkrumm.walkingpad.plist` (first run only; later runs
just kickstart it).
## Verify & Monitor

- **Health URL:** `http://127.0.0.1:7706/health` (loopback only, unauthenticated)
  → `{"ok":true,"version":"<short sha>"}`. `make verify` probes it and exits non-zero if
  the daemon is not live; `make version` prints the live `version` (exit 1 when unanswered).
- **Logs:** `~/Library/Logs/walkingpad.log` and `walkingpad.err`; `make logs`
  prints a bounded tail of both (no `-f`). `/tmp/walkingpad.log` is stale — the
  installer moved stdio to `~/Library/Logs` because macOS's periodic `/tmp`
  sweep unlinked the file while launchd still held the fd.
- **Kuma monitor name:** none — no walkingpad monitor is registered (the fleet is declared in
  the homelab repo's `uptime-kuma/monitors.yaml`). Host liveness is covered by the dev-host heartbeat.
- **OTel `service.name`:** none — the daemon has no OpenTelemetry instrumentation.

## Before changing Go code

Before changing anything under `internal/` or `cmd/`, Read `internal/AGENTS.md`: the P1's BLE,
counter and set-speed gotchas fail silently and live there.

## Layout

```
cmd/walkingpad/main.go                  # CLI entrypoint; compiled to `walkingpad`
internal/                                # the Go host: ble, session, store, api, sync, config, logger
raycast/                                 # TypeScript Raycast extension
scripts/                                 # plist, Info.plist.tmpl, build-app-bundle.sh, tools.sh, apple-slot.sh
contracts/fixtures/                      # golden API responses, written by internal/api/contract_test.go
apple/project.yml                        # XcodeGen spec of the Swift menu bar app (the .xcodeproj is generated)
apple/WalkingPad/                        # the app target: menu bar item, popover, Settings and History windows, hotkeys
apple/WalkingPad/Snapshots/              # the offscreen snapshot harness (SNAPSHOT_HARNESS builds only)
apple/Packages/PadKit/                   # API models, HTTP client, PadStore (polling, state, commands), HistoryStore; no UI code
```

## Swift client (`apple/`)

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
- `make snapshots` builds the app with `SNAPSHOT_HARNESS` (own derived data `apple/.dd-snap`) and draws
  the popover in every `PadPhase`, Settings and the History window (`history-*`), light and dark, offscreen
  against an in-memory host into `apple/.snapshots/` (`SNAP_DIR` overrides). `SNAP_LIVE_URL=http://127.0.0.1:7706`
  adds `popover-live-*` and `history-live-*` from the running host (GET only) and prints its state;
  `SNAP_LIVE_NOW=YYYY-MM-DD` sets History's "today" when the host's walks are old. Temp HOME, no Keychain,
  no login item, no network otherwise. Look at the PNGs after a UI change; there is no golden file.
  Prominent buttons and toggles draw greyed: an offscreen window of an accessory app is never active.

## Coding conventions

- **Strong typing.** No `interface{}` / `any` unless justified at a true protocol boundary. Use typed enums (`type BeltState uint8`) for everything that maps to a fixed wire value.
- **Table-driven tests.** Especially in `ble/frames` — every opcode + every fixture from the PRD goes in a table.
- **Errors are returned, not logged-and-swallowed.** Wrap with `fmt.Errorf("…: %w", err)`. Log at the top of the call stack.
- **No goroutine without a context.** Every long-running goroutine takes a `ctx context.Context` and respects cancellation. The daemon's `serve` command wires a single root context with signal handlers.
- **Atomic state.** Shared state (last status frame, current session) is owned by a single goroutine; other readers go through a channel or a mutex-guarded accessor. No "just one quick mutex" sprinkled in handlers.
- **No global state** outside `main.Version`.
- **Comments only where the why isn't obvious.** Don't restate `setSpeed` does what its name says. Document the reasoning behind the 700 ms gap, the `0x80` ack semantics, the 15-min session rule. Per global rules: no AI/tool attribution anywhere.

## Argo integration

- Argo lives at `~/SourceRoot/argo`. New domain goes in `apps/api/src/routes/walking-pad.ts`. New Drizzle table `walking_pad_sessions` in `apps/api/src/db/schema.ts`. Follow the `weight-log` domain as the template (single file per domain, no controllers/services).
- API base URL: `https://argo.jkrumm.com/api`. Bearer auth via `API_SECRET`.
- Token resolution in the daemon: env `KSWP_ARGO_TOKEN` overrides `argo.token` in config TOML. If neither is set the sync worker stays disabled — the binary does **not** shell out to `op` or `secrets-run` itself. The live LaunchAgent (`scripts/install-launch-agent.sh`) resolves it *before spawn* with `secrets-run read <ref>` (never `op run` directly — that hangs on the headless mini) and exports `KSWP_ARGO_TOKEN` into the plist's `ProgramArguments` shell wrapper. Non-jkrumm installs simply don't sync.

Per global rules: argo changes happen as a **separate PR** in the argo repo, never bundled with daemon commits.

## Don'ts

- ❌ Don't bypass the `.app` bundle to "make it simpler." It won't work.
- ❌ Don't add a second BLE client. There can only be one.
- ❌ Don't poll BLE faster than 1 Hz. The device drops frames.
- ❌ Don't trust the device's distance/steps across STANDBY transitions.
- ❌ Don't add a Garmin uploader. Explicit non-goal — see README's Why section.
- ❌ Don't add FTMS support. P1 doesn't speak it.
- ❌ Don't introduce a heavyweight HTTP framework. stdlib is fine.
- ❌ Don't put `*.sqlite` in the repo. `.gitignore` covers it; don't override.
- ❌ Don't add AI attribution to commits, PRs, or code. Global rule.
