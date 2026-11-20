# WalkingPad: a Swift app on top of the Go host

**Proposal.** Keep the Go daemon as the host on the Mac mini and build a native Swift menu bar app that talks to it over the existing HTTP API. No rewrite. Your verdict is asked on the three open choices below; each has a default that is taken after 24 hours.

## What exists (measured 2026-11-20)

| Fact | Value |
|-|-|
| Host | Go daemon, 6,000 lines plus tests, LaunchAgent `com.jkrumm.walkingpad` on the mini, connected to the P1 right now |
| Live build | `cd86289` from 2026-05-21; 12 later commits on master were never deployed, including the BLE library bump |
| API | 10 routes on `127.0.0.1:7706`, loopback only, optional bearer token |
| Data | SQLite on the mini, every closed session synced to Argo |
| Control surface | `raycast/`, 2,600 lines, defaults to loopback, so it only works on the mini |
| Last session | 2026-07-31 |
| Market | WalkingMate (App Store, 1.9.9 from 2026-10-17) sells menu bar control, hotkeys and history; four open-source Mac apps exist |

The menu bar controller already exists as a product, so this stays a personal tool with public source. What it adds: every session is recorded by an always-on machine next to the pad and lands in Argo.

## Design

```
MacBook                              Mac mini                     Pad
WalkingPad.app (Swift) ──HTTPS──▶ tailnet door ──▶ Go host ──BLE──▶ P1
  menu bar, hotkeys, history        bearer token     │
                                                     ├─▶ SQLite (source of truth)
                                                     └─▶ Argo (dashboards, Garmin context)
```

- **Host stays Go.** Its edge cases are verified on the hardware (counters reset on every stop, set-speed dropped during the ramp). A rewrite means proving each one again with a person on the belt.
- **The HTTP API is the seam.** The app knows only the routes. Go tests write each response as golden JSON under `contracts/`, and the Swift client decodes the same files: a changed response shape fails a test on both sides.
- **Remote access.** The host gets a second listener on loopback that refuses every request without a bearer token. The mini's Caddy door terminates TLS on the tailnet and forwards to it. The existing listener keeps serving the health probe unchanged. Starting a belt is physical actuation, so nothing is public: tailnet ACL plus token.
- **The app** is SwiftUI on macOS 26 under `apple/` (XcodeGen plus one local package, as Iris lays out its apps): a menu bar item with live speed, time and distance, a popover with start, stop and a speed stepper, global hotkeys, a history window with charts, settings.
- **Statistics** come from the host's SQLite through the API, the rows Argo is synced from. The app needs no Argo. Argo stays the place where walking sits next to Garmin data.
- **Factory.** `project.yaml` with `deploy.mode: make` for the host on the mini and lane `apple: 1`. Once Swift exists, a lead runs `make check-fast` and hosted macOS CI runs `make check`. Signing, the shared Xcode lock and the MacBook install script are copied from ntfy-mac.

## Open choices

| Choice | Default | Changing it later costs |
|-|-|-|
| Host language | Keep Go | Low. A Swift host can replace it behind the same routes; the cost is proving the belt edge cases again |
| Distribution | Owner installs only: a Developer ID signed and notarized build that the MacBook pulls from the mini after you approve one dialog showing the command | One row. Sparkle, GitHub Releases and a cask are additive and ntfy-mac has each script |
| Launcher | Hotkeys live in the app. `raycast/` stays untouched and is deleted once the app has run for 30 days | Tinycast commands are a separate small change in the personal extension; the API is the same either way |

## Rows (`docs/plan.yaml`)

| Row | What ships |
|-|-|
| `host-deploy-head` | master deployed to the mini with a rollback, `make version`, a guard that refuses a restart mid-session |
| `rename-sweep` | Go module, `cmd/` and docs follow the repo rename to `walkingpad-mac` |
| `host-remote-api` | the token-guarded remote listener |
| `door` (dotfiles) | the tailnet door to that listener |
| `app-skeleton` | `apple/`, the API client against golden fixtures, check tiers, CI |
| `app-menubar` | menu bar, popover, hotkeys, settings, snapshots |
| `app-history` | sessions and charts, plus the aggregate route they need |
| `app-install` | the signed build on the MacBook, first live start by the owner |
| `readme` | README for the new shape |

## Not doing

- No second BLE client: the Swift app owns no Bluetooth and no database.
- No FTMS or other pad models. The P1 speaks WiLink; newer pads split across three protocol families.
- No Apple Health, no Garmin upload, no App Store.
