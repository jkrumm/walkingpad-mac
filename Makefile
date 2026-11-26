# walkingpad-mac — single-target dev loop.
# Run `make` for the menu, `make up` for everything else.

BINARY        := walkingpad
APP_NAME      := WalkingPad
CMD_DIR       := ./cmd/walkingpad
BIN_DIR       := ./bin
APP_BUNDLE    := $(BIN_DIR)/$(APP_NAME).app
APP_INSTALL   := /Applications/$(APP_NAME).app
PLIST_LABEL   := com.jkrumm.$(BINARY)
PLIST_TMPL    := ./scripts/$(PLIST_LABEL).plist.tmpl
PLIST_DST     := $(HOME)/Library/LaunchAgents/$(PLIST_LABEL).plist
LOG_DIR       := $(HOME)/Library/Logs
LOG_OUT       := $(LOG_DIR)/$(BINARY).log
LOG_ERR       := $(LOG_DIR)/$(BINARY).err
HTTP_PORT     := 7706
DATA_DIR      := $(HOME)/Library/Application Support/$(APP_NAME)

# Swift client (apple/): sources the format and lint tiers read, pinned tools, the Xcode slot.
SWIFT_FILES   := apple/WalkingPad apple/Packages/PadKit/Sources apple/Packages/PadKit/Tests apple/Packages/PadKit/Package.swift
PADKIT        := apple/Packages/PadKit
TOOLS         := scripts/tools.sh
APPLE_SLOT    := scripts/apple-slot.sh
# Build jobs cap for every xcodebuild here: the uncapped build starts one swift-frontend per core (12), which peaked the
# walkingpad-mac-apple slot step at ~2.9 GiB. Two jobs at low priority, as iris does; CI (CI set) has a runner of its own.
SWIFT_JOBS    ?= 2
XCB_NICE      := $(if $(CI),,nice -n 10)
XCB_CAP       := $(if $(CI),,-jobs $(SWIFT_JOBS) IDEBuildOperationMaxNumberOfConcurrentCompileTasks=$(SWIFT_JOBS))
XCB           := $(XCB_NICE) xcodebuild $(XCB_CAP)
# make snapshots: a separate Debug build with SNAPSHOT_HARNESS (own derived data, so the app that
# check-apple builds never contains the harness); PNGs land in SNAP_DIR.
SNAP_APP      := apple/.dd-snap/Build/Products/Debug/WalkingPad.app
SNAP_DIR      ?= apple/.snapshots
# make app-release: the Developer ID signed and notarized menu bar app. It is built where the repo lives and kept under
# the state dir (not in the worktree, which goes away) so make install-macbook can pull it from the mini.
CLIENT_DD     := apple/.dd-release
CLIENT_BUILT  := $(CLIENT_DD)/Build/Products/Release/$(APP_NAME).app
CLIENT_DIR    := $(HOME)/.local/state/$(BINARY)/client
CLIENT_APP    := $(CLIENT_DIR)/$(APP_NAME).app
NOTARIZE      ?= 1

VERSION       := $(shell ./scripts/build-version.sh)
ROLLBACK_DIR  := $(HOME)/.local/state/$(BINARY)/rollback
ROLLBACK_APP  := $(ROLLBACK_DIR)/$(APP_NAME).app
HEALTH_URL    := http://127.0.0.1:$(HTTP_PORT)/health
LDFLAGS       := -ldflags "-X main.Version=$(VERSION) -s -w"

.DEFAULT_GOAL := help

help: ## (default) print this menu
	@printf "WalkingPad \033[1m%s\033[0m\n\n" "$(VERSION)"
	@awk 'BEGIN {FS = ":.*##"; printf "Targets:\n"} \
	  /^[a-zA-Z_-]+:.*?##/ {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf "\n\033[1mNormal flow\033[0m\n"
	@printf "  1. \033[36mmake up\033[0m   — every time you change Go or Raycast code.\n"
	@printf "                It rebuilds the daemon, swaps /Applications/WalkingPad.app,\n"
	@printf "                kickstarts the LaunchAgent, prints the live version for\n"
	@printf "                confirmation, then starts the Raycast dev loop.\n"
	@printf "  2. \033[36mmake logs\033[0m — print the last daemon log lines (bounded).\n"
	@printf "  3. \033[36mmake check-fast\033[0m — Go, Raycast and Swift checks; \033[36mmake check\033[0m adds the app build.\n"

check: check-fast check-apple ## the full gate (CI runs it): check-fast plus the Xcode build of the app

check-fast: ## the lead's tier, no xcodebuild: gofmt, vet, golangci-lint, go test -race, raycast tsc, Swift lint, swift test
	@unformatted=$$(gofmt -l $$(git ls-files '*.go')); \
	  if [ -n "$$unformatted" ]; then echo "gofmt: files need formatting:"; echo "$$unformatted"; exit 1; fi
	go vet ./...
	$(MAKE) --no-print-directory lint
	$(MAKE) --no-print-directory test
	$(MAKE) --no-print-directory lint-swift
	$(MAKE) --no-print-directory test-swift

check-apple: ## xcodegen + xcodebuild of apple/WalkingPad through scripts/apple-slot.sh (one Xcode job on the mini)
	cd apple && "$$(../$(TOOLS) xcodegen)" generate --quiet
	$(APPLE_SLOT) $(XCB) -project apple/WalkingPad.xcodeproj -scheme WalkingPad -configuration Debug \
	  -destination 'platform=macOS' -derivedDataPath apple/.dd CODE_SIGNING_ALLOWED=NO build

lint-swift: ## swift format lint + SwiftLint (pinned by scripts/tools.sh) over apple/
	swift format lint --strict -r $(SWIFT_FILES)
	$(TOOLS) --self-test
	"$$($(TOOLS) swiftlint)" lint --strict --no-cache --quiet

test-swift: ## swift test of apple/Packages/PadKit (decodes contracts/fixtures)
	cd $(PADKIT) && swift test

snapshots: ## draw the popover in every state and Settings, light and dark, offscreen into SNAP_DIR (SNAP_LIVE_URL adds the live host, GETs only)
	cd apple && "$$(../$(TOOLS) xcodegen)" generate --quiet
	$(APPLE_SLOT) $(XCB) -project apple/WalkingPad.xcodeproj -scheme WalkingPad -configuration Debug \
	  -destination 'platform=macOS' -derivedDataPath apple/.dd-snap CODE_SIGNING_ALLOWED=NO \
	  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) SNAPSHOT_HARNESS' build
	home=$$(mktemp -d) && trap 'rm -r "$$home"' EXIT && \
	  HOME="$$home" CFFIXED_USER_HOME="$$home" $(SNAP_APP)/Contents/MacOS/WalkingPad --ui-snapshot "$(SNAP_DIR)"

app-release: ## Release build of the menu bar app, Developer ID signed, notarized and stapled into CLIENT_APP (NOTARIZE=0 signs only)
	cd apple && "$$(../$(TOOLS) xcodegen)" generate --quiet
	$(APPLE_SLOT) $(XCB) -project apple/WalkingPad.xcodeproj -scheme WalkingPad -configuration Release \
	  -destination 'platform=macOS' -derivedDataPath $(CLIENT_DD) CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
	  MARKETING_VERSION=$(VERSION) CURRENT_PROJECT_VERSION=$$(git rev-list --count HEAD) build
	rm -rf "$(CLIENT_APP)" && mkdir -p "$(CLIENT_DIR)" && ditto $(CLIENT_BUILT) "$(CLIENT_APP)"
	NOTARIZE=$(NOTARIZE) $(APPLE_SLOT) scripts/sign.sh "$(CLIENT_APP)"
	@printf "client built  : \033[1m%s\033[0m  %s\n" "$(VERSION)" "$(CLIENT_APP)"

verify-app: ## check the built menu bar app: Developer ID, Hardened Runtime, stapled, Gatekeeper (NOTARIZE=0: signature only)
	scripts/verify-signature.sh "$(CLIENT_APP)" $(if $(filter 0,$(NOTARIZE)),--developer-id,--release)

install-macbook: ## pull the built app onto the MacBook (one approval dialog): verify, host URL, token into the Keychain, relaunch
	scripts/install-macbook.sh "$(CLIENT_APP)"

test-live: ## PadKit decodes GET /status and /sessions from the live host (reads only)
	cd $(PADKIT) && PADKIT_LIVE_URL=http://127.0.0.1:$(HTTP_PORT) swift test --filter LiveHostTests

contracts: ## rewrite contracts/fixtures from the API handlers after an intended response change
	go test ./internal/api -run TestContractFixtures -count=1 -update

up: deploy ## rebuild daemon, deploy, reload, verify, start Raycast dev (the one command for everything)
	@./scripts/raycast-dev.sh

deploy: ## ship the current build to /Applications and restart the LaunchAgent (refuses mid-walk; FORCE=1 overrides)
	@mkdir -p $(BIN_DIR)
	go build $(LDFLAGS) -o $(BIN_DIR)/$(BINARY) $(CMD_DIR)
	./scripts/build-app-bundle.sh $(BIN_DIR)/$(BINARY) $(VERSION) $(APP_BUNDLE)
	@mkdir -p "$(DATA_DIR)" "$(HOME)/Library/LaunchAgents"
	@if [ ! -f $(PLIST_DST) ]; then \
	  echo "first-run: installing LaunchAgent plist"; \
	  ./scripts/install-launch-agent.sh $(PLIST_TMPL) $(PLIST_DST); \
	  launchctl load -w $(PLIST_DST); \
	fi
	@./scripts/deploy-guard.sh
	@if [ -d $(APP_INSTALL) ]; then \
	  rm -rf $(ROLLBACK_DIR) && mkdir -p $(ROLLBACK_DIR) && ditto $(APP_INSTALL) $(ROLLBACK_APP) \
	    && echo "rollback copy : $(ROLLBACK_APP)"; \
	fi
	rm -rf $(APP_INSTALL)
	cp -R $(APP_BUNDLE) $(APP_INSTALL)
	launchctl kickstart -k gui/$$(id -u)/$(PLIST_LABEL)
	@sleep 1
	@printf "daemon source : \033[1m%s\033[0m\n" "$(VERSION)"
	@printf "daemon live   : %s\n" "$$($(MAKE) --no-print-directory version 2>/dev/null || echo '(no /health response yet — agent may still be booting)')"
	@echo "---"

version: ## print the sha the live daemon reports on /health (exit 1 when it does not answer)
	@v=$$(curl -fsS --max-time 3 $(HEALTH_URL) 2>/dev/null | sed -n 's/.*"version":"\([^"]*\)".*/\1/p'); \
	  if [ -n "$$v" ]; then echo "$$v"; else echo "walkingpad: no version from $(HEALTH_URL)" >&2; exit 1; fi

rollback: ## reinstall the bundle the last deploy replaced and restart the LaunchAgent (refuses mid-walk; FORCE=1 overrides)
	@[ -d $(ROLLBACK_APP) ] || { echo "rollback: no saved bundle at $(ROLLBACK_APP)" >&2; exit 1; }
	@./scripts/deploy-guard.sh
	rm -rf $(APP_INSTALL)
	ditto $(ROLLBACK_APP) $(APP_INSTALL)
	launchctl kickstart -k gui/$$(id -u)/$(PLIST_LABEL)
	@sleep 1
	@printf "daemon live   : %s\n" "$$($(MAKE) --no-print-directory version 2>/dev/null || echo '(no /health response yet)')"

# The Raycast typecheck needs its devDependencies, and a fresh checkout has no node_modules. CI runs the
# same install before make check, so the rule is a no-op there. The stamp is written only after npm ci
# succeeds: npm ci wipes node_modules first, so a directory's mtime cannot say the install finished.
raycast/node_modules/.make-installed: raycast/package-lock.json raycast/package.json
	npm ci --prefix raycast
	touch $@

test: raycast/node_modules/.make-installed ## run all tests (Go race + Raycast typecheck)
	./scripts/test-deploy-guard.sh
	./scripts/test-build-app-bundle.sh
	./scripts/test-install-macbook.sh
	go test -race -count=1 ./...
	cd raycast && npx tsc --noEmit

verify: ## probe the running daemon's /health — exit 0 = live and healthy
	@curl -fsS http://127.0.0.1:$(HTTP_PORT)/health >/dev/null \
	  && echo "walkingpad: live — /health OK" \
	  || { echo "walkingpad: NOT live — /health failed" >&2; exit 1; }

logs: ## print a bounded tail of the daemon logs in ~/Library/Logs, then exit
	@for f in $(LOG_OUT) $(LOG_ERR); do \
	  printf "\n==> %s <==\n" "$$f"; \
	  if [ -f "$$f" ]; then tail -n 50 "$$f"; else echo "(missing)"; fi; \
	done

scan: ## list nearby WalkingPad BLE devices (dev tool, not the daemon)
	@mkdir -p $(BIN_DIR)
	@go build $(LDFLAGS) -o $(BIN_DIR)/$(BINARY) $(CMD_DIR)
	$(BIN_DIR)/$(BINARY) scan

fmt: ## format Go + Swift, tidy modules
	gofmt -s -w .
	go mod tidy
	swift format --in-place -r $(SWIFT_FILES)

lint: ## run golangci-lint (pre-commit hook also runs this)
	@which golangci-lint > /dev/null || (echo "install: brew install golangci-lint" && exit 1)
	golangci-lint run ./...

clean: ## remove build artifacts
	rm -rf $(BIN_DIR) coverage.out apple/.dd apple/.dd-snap apple/.dd-release apple/.snapshots apple/WalkingPad.xcodeproj $(PADKIT)/.build

.PHONY: help check check-fast check-apple app-release verify-app install-macbook lint-swift test-swift snapshots test-live contracts up deploy version rollback test verify logs scan fmt lint clean
