# Repo-root test orchestration (bluegull-aqi-mtm.13), following Plant-
# Tracer's Makefile idiom: everything runnable from a bash command line, no
# Xcode GUI required. `service/Makefile` already covers the Python side in
# detail (poetry, DynamoDB Local, SAM); this delegates to it rather than
# duplicating it.
.PHONY: mac-dev-setup test test-swift test-snapshots test-ui test-service snapshots record-snapshots \
        app-build app-run app-launch app-stop app-clean widget-reset app-package \
        service-deploy service-delete service-enable service-disable

MAC_APP_DIR := mac-app
SERVICE_DIR := service
SNAPSHOT_SCRATCH_DIR := /tmp/bluegull-widget-snapshots
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

# app-package scratch dir -- gitignored, safe to rm -rf and rebuild from
# scratch every run (see app-package below).
PACKAGE_BUILD_DIR := $(MAC_APP_DIR)/build
PACKAGE_ARCHIVE := $(PACKAGE_BUILD_DIR)/BluegullAQI.xcarchive
PACKAGE_EXPORT_DIR := $(PACKAGE_BUILD_DIR)/export
PACKAGE_APP := $(PACKAGE_EXPORT_DIR)/BluegullAQI.app
# create-dmg copies everything in its source folder into the DMG verbatim
# -- $(PACKAGE_EXPORT_DIR) isn't safe to point it at directly, since
# `xcodebuild -exportArchive` also drops DistributionSummary.plist,
# ExportOptions.plist, and Packaging.log in there alongside the .app
# (confirmed by actually inspecting the export dir, not assumed). This is
# a clean staging copy of just the .app, built fresh every run.
PACKAGE_DMG_SOURCE_DIR := $(PACKAGE_BUILD_DIR)/dmg-source
# Name of the one-time `xcrun notarytool store-credentials` keychain
# profile -- see doc/DEVINSTALL.md "Package for ad-hoc distribution" for
# setup. Not a secret itself (just a label); the credentials it points to
# live in the login keychain, never in this repo.
NOTARY_PROFILE := bluegull-aqi-notary
# bluegull-aqi-fw4.9: CURRENT_PROJECT_VERSION (the build number that must
# actually disambiguate one build from another -- MARKETING_VERSION in
# project.yml is hand-bumped and stays the same across many builds) comes
# from the git commit count, not a hand-maintained counter -- monotonic for
# free as long as commits keep happening, no state file to forget to bump.
# GIT_SHA is the short commit hash, stamped into Info.plist's GitCommitSHA
# key (see project.yml) so a distributed .app/.dmg traces back to an exact
# commit. `-dirty` flags a build made from an uncommitted working tree --
# deliberately loud, since a "clean" git commit-based build number is a lie
# if the tree wasn't actually clean when it was built.
GIT_SHA := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)$(shell git diff --quiet HEAD -- 2>/dev/null || echo -dirty)
GIT_BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)
XCODEBUILD_VERSION_OVERRIDES := GIT_COMMIT_SHA=$(GIT_SHA) CURRENT_PROJECT_VERSION=$(GIT_BUILD_NUMBER)
# DMG Finder-window layout (bluegull-aqi-b3r) -- window size in points,
# icon centers in the same coordinate space. Keep DMG_ICON_X/DMG_APPLINK_X
# averaging to half of DMG_WINDOW_W so the pair stays centered in the
# window; mac-app/branding/dmg-background.png's arrow was hand-drawn to
# match these exact numbers, so change both together.
DMG_WINDOW_W := 660
DMG_WINDOW_H := 400
DMG_ICON_SIZE := 128
DMG_ICON_X := 180
DMG_ICON_Y := 170
DMG_APPLINK_X := 480
DMG_APPLINK_Y := 170

# One-time setup for a genuinely fresh macOS install (bluegull-aqi-x0u) --
# gets you from "brand new Mac" to able to run test-swift/app-run/
# test-service. Idempotent: brew/pipx/poetry all no-op on an
# already-satisfied dependency, so re-running after fixing whatever step
# failed is safe.
#
# Manual, GUI-only steps this CANNOT do for you -- do these FIRST, then run
# `make mac-dev-setup`:
#   1. Install Xcode from the Mac App Store (the full app, not just the
#      Command Line Tools -- this project needs the real macOS SDK/Swift
#      toolchain). Open it once and let it finish installing components.
#   2. Sign into Xcode with the Apple ID for this project's Developer
#      account: Xcode -> Settings -> Accounts -> "+". Needed for
#      Automatic signing against team G5DWPBWHQ5 (make app-build/app-run)
#      -- see doc/DEVINSTALL.md if signing fails afterward.
#   3. Install a password/secrets manager with CLI-based secret resolution
#      -- you'll want it for the local AirNow key below (see
#      service/README.md). It's still a real credential; treat it as one
#      rather than a literal in `.env`, gitignored or not. `service/
#      .env.example` shows 1Password's `op run --env-file=.env --
#      <command>` as a worked example of the pattern, not a requirement --
#      any manager with an equivalent CLI works the same way.
#
# And after this target finishes, more manual/interactive steps -- none of
# these are scriptable, each needs a live browser/SSO or device-linked
# login, so they're just echoed as a reminder below rather than run here:
#   - `aws sso login --profile AdministratorAccess-843088391598` -- only
#     needed for `make service-deploy`/`service-delete`/etc, not for local
#     dev or `make test`. Account/profile background: doc/DESIGN.md "AWS
#     account".
#   - `gh auth login` (GitHub CLI).
#   - Your own free AirNow key from airnowapi.org, for Direct mode --
#     Service mode (the app's default, see doc/DEVINSTALL.md) needs none.
mac-dev-setup:
	@test -d /Applications/Xcode.app || { \
		echo "Xcode.app not found in /Applications -- install it from the Mac App Store first (see this target's header comment above), then re-run 'make mac-dev-setup'."; \
		exit 1; \
	}
	sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
	sudo xcodebuild -license accept
	@if command -v brew >/dev/null 2>&1; then \
		echo "Homebrew already installed -- skipping install."; \
	else \
		echo "Homebrew not found -- installing..."; \
		/bin/bash -c "$$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; \
	fi
	@# One shell chain from here on, not separate Make recipe lines --
	@# `brew shellenv`/pipx's install dir need to land on PATH for every
	@# step after them (xcodegen, poetry, dynamodb_local.py's `poetry
	@# run`), and a fresh install's PATH update only reaches a *new* login
	@# shell, never this non-interactive one or a subsequent recipe line
	@# (each is its own subshell in plain Make).
	eval "$$([ -x /opt/homebrew/bin/brew ] && /opt/homebrew/bin/brew shellenv || /usr/local/bin/brew shellenv)" && \
	brew install xcodegen create-dmg aws-sam-cli awscli gh beads betterleaks openjdk pipx python@3.14 && \
	pipx install poetry && \
	export PATH="$$HOME/.local/bin:$$PATH" && \
	(cd $(MAC_APP_DIR) && xcodegen generate) && \
	(cd $(SERVICE_DIR) && poetry env use "$$(brew --prefix python@3.14)/bin/python3.14" && poetry install) && \
	(cd $(SERVICE_DIR) && poetry run python3 bin/dynamodb_local.py setup)
	git config core.hooksPath .beads/hooks
	test -f $(SERVICE_DIR)/.env || cp $(SERVICE_DIR)/.env.example $(SERVICE_DIR)/.env
	@echo ""
	@echo "mac-dev-setup done. Remaining manual steps (see this target's header comment):"
	@echo "  - Sign into Xcode with the project's Apple ID (Xcode -> Settings -> Accounts)"
	@echo "  - aws sso login --profile AdministratorAccess-843088391598  (only needed for service-deploy etc.)"
	@echo "  - gh auth login"
	@echo "  - Set a real AIRNOW_API_KEY in service/.env if you want Direct mode or 'make run-local' -- store it in a secrets manager and reference it, don't paste the literal key in even though .env is gitignored (service/.env.example shows the 1Password example)"
	@echo "  - 'bd ready' should show issues; if it looks empty, run 'bd doctor' (Dolt data syncs separately from this git clone)"
	@echo "Then try: make test-swift / make app-run / make test-service"

# Everything except test-ui and test-snapshots -- see each target's own
# comment for why it's not part of the default run.
test: test-swift test-service

# Full BluegullAQI scheme (container app + widget extension) plus the
# BluegullAQIKit Swift package (BluegullAQIKitTests and
# BluegullAQIWidgetViewsTests's "renders without crashing" checks) --
# unsigned, so this needs no Apple Developer account or real device.
# Deliberately skips the BluegullAQIWidgetSnapshotTests target -- see
# test-snapshots below for why.
test-swift:
	cd $(MAC_APP_DIR) && xcodegen generate
	cd $(MAC_APP_DIR) && xcodebuild build -scheme BluegullAQI -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
	cd $(MAC_APP_DIR) && xcodebuild test -scheme BluegullAQI -destination 'platform=macOS' -only-testing:BluegullAQITests CODE_SIGNING_ALLOWED=NO
	cd $(MAC_APP_DIR)/BluegullAQIKit && swift test --skip BluegullAQIWidgetSnapshotTests

# Pixel-level golden-image comparison for the widget's per-family layouts
# (bluegull-aqi-mtm.11), split into its own target and make target
# (bluegull-aqi-67l) -- confirmed via CI failing this way on every run
# since the workflow was added (2026-08-01): GoldenImageAssertion's
# tolerance (0.5% mismatch) is tight enough that font/SF Symbol
# rasterization differences between the machine that recorded
# __Snapshots__/ and whatever machine runs the test alone produce
# failures, never an actual visual regression. Same "different environment
# renders differently" problem as test-ui below, just for pixels instead
# of TCC permissions -- kept out of the default `test`/`test-swift` gate
# for the same reason, run this deliberately (or record new goldens with
# RECORD_SNAPSHOTS=1, see BluegullAQIWidgetSnapshotTests.swift) after a
# real widget UI change, and compare by eye before committing.
test-snapshots:
	cd $(MAC_APP_DIR) && xcodegen generate
	cd $(MAC_APP_DIR)/BluegullAQIKit && swift test --filter BluegullAQIWidgetSnapshotTests

# Separate from `test-swift`/`test` on purpose -- bluegull-aqi-e70.9 found
# XCUITest's runner needs a logged-in GUI session with Accessibility/
# Automation TCC permission granted to the process running `xcodebuild
# test`, which a headless/CI-style environment doesn't have (confirmed via
# a real, diagnosed 380-second failure, not a guess). Folding this into the
# default `make test` would make it hang or fail somewhere that can't grant
# that permission -- run this deliberately, from a real interactive session.
test-ui:
	cd $(MAC_APP_DIR) && xcodegen generate
	cd $(MAC_APP_DIR) && xcodebuild test -scheme BluegullAQI -destination 'platform=macOS' -only-testing:BluegullAQIUITests CODE_SIGNING_ALLOWED=NO

# The service-side pytest suite -- delegates to service/Makefile, which
# owns the DynamoDB Local fixture lifecycle (downloads its own jar on
# demand; needs `java`, not Docker).
test-service:
	$(MAKE) -C $(SERVICE_DIR) pytest

# Real AWS actions -- all four just delegate to service/Makefile, which
# owns the actual implementations (deploy/delete/enable/disable) since
# they need SAM/aws CLI context that lives there. `ENV=stage` (etc.)
# passed on the command line forwards through automatically (GNU Make
# exports command-line variable assignments to sub-makes). Default ENV is
# "dev" -- see service/Makefile's own comment on why.
service-deploy:
	$(MAKE) -C $(SERVICE_DIR) deploy

service-delete:
	$(MAKE) -C $(SERVICE_DIR) delete

service-enable:
	$(MAKE) -C $(SERVICE_DIR) enable

service-disable:
	$(MAKE) -C $(SERVICE_DIR) disable

# Renders the widget's small/medium/large/no-data fixtures to PNGs for
# direct visual inspection (bluegull-aqi-mtm.10) -- a scratch directory,
# NOT the committed golden images `record-snapshots` updates below.
snapshots:
	mkdir -p $(SNAPSHOT_SCRATCH_DIR)
	cd $(MAC_APP_DIR)/BluegullAQIKit && swift run WidgetRenderHarness $(SNAPSHOT_SCRATCH_DIR)
	@echo "Rendered widget snapshots to $(SNAPSHOT_SCRATCH_DIR)"

# Re-records the golden PNGs the snapshot regression tests compare against
# (bluegull-aqi-mtm.11). Only run this after confirming a rendering change
# is actually intentional -- review the resulting diff under
# mac-app/BluegullAQIKit/Tests/BluegullAQIWidgetSnapshotTests/__Snapshots__/
# before committing it. Recording itself always reports failures (that's
# how it flags "these are new, go look at them," not a real problem) --
# the `|| true` keeps that from failing the make invocation.
record-snapshots:
	cd $(MAC_APP_DIR)/BluegullAQIKit && RECORD_SNAPSHOTS=1 swift test --filter BluegullAQIWidgetSnapshotTests || true
	@echo "Golden images re-recorded -- review the diff before committing."

# Real signed build (NOT CODE_SIGNING_ALLOWED=NO like test-swift -- App
# Sandbox needs an actual signature to launch at all). See doc/DEVINSTALL.md
# "Install / run". Needs Xcode signed into the Apple ID that registered the
# solutions.bluegull.aqi bundle IDs/App Group (bluegull-aqi-8ef.5); if
# signing fails, open the project in Xcode once to resolve/select the team,
# or pass DEVELOPMENT_TEAM=XXXXXXXXXX here.
app-build:
	cd $(MAC_APP_DIR) && xcodegen generate
	cd $(MAC_APP_DIR) && xcodebuild build -scheme BluegullAQI -configuration Debug -destination 'platform=macOS' -allowProvisioningUpdates $(XCODEBUILD_VERSION_OVERRIDES)

# Builds, then launches the result -- the command-line equivalent of
# Xcode's own Cmd+R. `app-build` is .PHONY, so `xcodegen generate` and
# `xcodebuild build` always run here, every time -- but xcodebuild's own
# incremental compilation means that's fast (a quick "nothing changed"
# check), not a true from-scratch rebuild. See app-launch below if you
# want to skip that check entirely.
app-run: app-build
	$(MAKE) app-launch

# Launches whatever's already built, without invoking xcodegen or
# xcodebuild at all -- for when you know nothing's changed since the last
# app-build/app-run and just want to relaunch fast. Fails with a clear
# Xcode error if nothing's been built yet (run app-build/app-run first).
app-launch:
	@cd $(MAC_APP_DIR) && \
	app_path=$$(xcodebuild -scheme BluegullAQI -configuration Debug -showBuildSettings -json 2>/dev/null \
		| python3 -c "import json,sys; d=json.load(sys.stdin); s=next(e for e in d if e['target']=='BluegullAQI')['buildSettings']; print(s['BUILT_PRODUCTS_DIR'] + '/' + s['FULL_PRODUCT_NAME'])") && \
	echo "Launching $$app_path" && \
	open "$$app_path"

# Just stops the running instance -- nothing else. Separate from app-clean
# since "I want to kill it and rebuild" and "I want to leave no trace" are
# different, common-enough-to-distinguish needs.
app-stop:
	-pkill -x BluegullAQI

# Fixes the widget silently disappearing from the Notification Center/
# desktop widget gallery -- diagnosed 2026-08-04: after a DerivedData wipe
# (or an Xcode "Clean Build Folder"), LaunchServices is left with two
# registrations for solutions.bluegull.aqi.widget -- the live one plus a
# stale one pointing at a DerivedData hash that no longer exists on disk.
# `chronod` (the widget host) can't tell which is authoritative, so it
# silently drops the extension: `log show --predicate 'process == "chronod"'`
# shows "Ignoring restricted or unknown extension solutions.bluegull.aqi.widget"
# even though `pluginkit -m` still lists it as registered. Logging out and
# back in does NOT clear this -- it's LaunchServices database state, not
# anything session-scoped.
# Finds every LaunchServices registration under any BluegullAQI-* DerivedData
# hash (stale or current -- lsregister re-adds the current one cleanly next
# launch) and unregisters it, then restarts chronod so it drops its cached
# "ignoring" state. Safe/reversible: LaunchServices re-indexes automatically,
# but chronod restarting briefly resets every widget on the Mac, not just
# this app's, while it re-registers.
#
# Also restarts NotificationCenter.app (bluegull-aqi-6qy, confirmed
# 2026-08-11): that's the process that actually draws the "Add Widgets"
# gallery picker, and it caches the icon it first resolved for an app --
# separate from both chronod above and from LaunchServices' own
# registration. Reproduced directly: a build with a real, correctly-
# compiled AppIcon (Assets.car/AppIcon.icns confirmed present, correctly
# codesigned) still showed a blank placeholder in the gallery sidebar until
# NotificationCenter was restarted, even after the chronod/LaunchServices
# reset above. Safe/reversible -- it's a normal user-session agent, killing
# it just relaunches it, same as Dock or Finder.
widget-reset:
	@paths=$$($(LSREGISTER) -dump 2>/dev/null \
		| grep -E '^[[:space:]]*path:.*DerivedData/BluegullAQI-.*/BluegullAQI(Widget\.appex|\.app)( \(0x[0-9a-fA-F]+\))?$$' \
		| sed -E 's/^[[:space:]]*path:[[:space:]]+(.*) \(0x[0-9a-fA-F]+\)$$/\1/' \
		| sort -u); \
	if [ -z "$$paths" ]; then \
		echo "No LaunchServices registrations found for BluegullAQI -- nothing to reset."; \
	else \
		echo "$$paths" | while IFS= read -r p; do \
			echo "Unregistering $$p"; \
			$(LSREGISTER) -u -v "$$p" >/dev/null 2>&1 || true; \
		done; \
	fi
	-killall chronod
	-killall NotificationCenter
	@echo "Widget registration reset. Relaunch the app (app-launch/app-run), then re-check the widget gallery."

# Reverses app-build/app-run (or any prior Xcode Cmd+R run) -- see
# doc/DEVINSTALL.md "Uninstall (leave no trace)" for what each step
# corresponds to. Stops the app first (app-stop) before touching its
# DerivedData build. Two things this can't do: reliably clear the Keychain
# item (`security`'s CLI doesn't consistently target iCloud-synchronizable
# items the way SecItemAdd's kSecAttrSynchronizable does -- clear it from
# the app's own Settings before running this, or verify in Keychain
# Access.app after), and remove a widget placed on the desktop (no CLI for
# that).
app-clean: app-stop widget-reset
	# Before the DerivedData wipe below, not after -- tccutil needs to
	# resolve the bundle identifier via LaunchServices, which it can't do
	# once the built .app is gone ("No such bundle identifier"). This
	# ordering only helps if a build currently exists, though: tccutil
	# needs *some* registered BluegullAQI.app to resolve against, built or
	# not deleted yet -- if app-clean is run a second time with no
	# `app-build`/`app-run` in between, there's nothing to resolve and this
	# fails every time regardless of order (confirmed empirically, not just
	# reasoned about). `-` ignores that failure rather than aborting the
	# rest of this target and skipping the reminders below -- if you
	# specifically need the location-permission reset to actually take
	# effect, run `app-build` first.
	#
	# widget-reset (in the prerequisite list, so it runs before any of this)
	# unregisters BluegullAQI/BluegullAQIWidget from LaunchServices while
	# the DerivedData below still exists to resolve against -- the exact
	# same resolve-before-delete constraint as tccutil above. Skipping it
	# here would recreate the stale-registration widget-gallery bug this
	# target was added to prevent.
	-tccutil reset Location solutions.bluegull.aqi
	rm -rf ~/Library/Developer/Xcode/DerivedData/BluegullAQI-*
	-security delete-generic-password -s solutions.bluegull.aqi.airnow-api-key -a airnow-api-key >/dev/null 2>&1
	-defaults delete solutions.bluegull.aqi >/dev/null 2>&1
	rm -rf ~/Library/Group\ Containers/group.solutions.bluegull.aqi
	@echo "Done. Verify the AirNow key is actually gone via Keychain Access.app (see comment above)."
	@echo "If you placed the widget on your desktop, remove it manually (right-click > Remove Widget)."

# One-off ad-hoc distribution outside the Mac App Store (bluegull-aqi-do1,
# bluegull-aqi-b3r) -- e.g. sending a signed build to a friend to try out.
# Distinct from the App Store submission path (bluegull-aqi-fw4 epic): this
# never touches App Store Connect. Archives Release, exports with the
# Developer ID method (mac-app/ExportOptions.plist), notarizes, staples the
# ticket, then builds a nice DMG (custom volume icon, branded background,
# Applications drop-link -- see mac-app/branding/README.md) under
# $(PACKAGE_BUILD_DIR) (gitignored scratch dir, wiped and rebuilt from
# scratch every run).
#
# Needs `create-dmg` (`brew install create-dmg`, or `make mac-dev-setup`)
# and a real logged-in GUI session: unlike every other step here,
# create-dmg drives Finder with AppleScript to arrange the window/icons --
# same class of constraint as test-ui needing a real Accessibility-enabled
# session, so this target won't work unattended/headless (not an issue in
# practice, since notarization below already needs interactive credential
# setup and this has never run in CI).
#
# One-time setup this depends on and can't script itself (both need
# interactive Apple ID auth / secrets that must never enter this repo --
# see CLAUDE.md's secrets rule):
#   1. A "Developer ID Application" certificate for team G5DWPBWHQ5 in your
#      login keychain -- Xcode -> Settings -> Accounts -> Manage
#      Certificates -> "+" -> Developer ID Application, if you don't have
#      one yet.
#   2. `xcrun notarytool store-credentials $(NOTARY_PROFILE) --apple-id <your-apple-id> \
#        --team-id G5DWPBWHQ5 --password <app-specific-password>` (generate
#      the app-specific password at appleid.apple.com) -- stores the
#      credential in your login keychain under the $(NOTARY_PROFILE) label,
#      once, outside this repo.
app-package:
	@echo "Packaging build $(GIT_BUILD_NUMBER) ($(GIT_SHA))"
	cd $(MAC_APP_DIR) && xcodegen generate
	rm -rf $(PACKAGE_BUILD_DIR)
	mkdir -p $(PACKAGE_BUILD_DIR)
	cd $(MAC_APP_DIR) && xcodebuild archive -scheme BluegullAQI -configuration Release \
		-archivePath build/BluegullAQI.xcarchive -allowProvisioningUpdates $(XCODEBUILD_VERSION_OVERRIDES)
	cd $(MAC_APP_DIR) && xcodebuild -exportArchive -archivePath build/BluegullAQI.xcarchive \
		-exportPath build/export -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates
	ditto -c -k --keepParent $(PACKAGE_APP) $(PACKAGE_BUILD_DIR)/BluegullAQI.zip
	xcrun notarytool submit $(PACKAGE_BUILD_DIR)/BluegullAQI.zip \
		--keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(PACKAGE_APP)
	@# .icns for create-dmg's --volicon, built at package time from the
	@# same checked-in PNGs Xcode uses for the app icon itself (bluegull-
	@# aqi-b3r) -- iconutil requires its input directory to literally be
	@# named *.iconset and contain only the icon PNGs, no Contents.json,
	@# hence the copy into a scratch dir rather than pointing at
	@# Assets.xcassets/AppIcon.appiconset directly.
	rm -rf $(PACKAGE_BUILD_DIR)/AppIcon.iconset
	mkdir -p $(PACKAGE_BUILD_DIR)/AppIcon.iconset
	cp $(MAC_APP_DIR)/BluegullAQI/Assets.xcassets/AppIcon.appiconset/icon_*.png \
		$(PACKAGE_BUILD_DIR)/AppIcon.iconset/
	iconutil -c icns $(PACKAGE_BUILD_DIR)/AppIcon.iconset -o $(PACKAGE_BUILD_DIR)/BluegullAQI.icns
	rm -rf $(PACKAGE_DMG_SOURCE_DIR)
	mkdir -p $(PACKAGE_DMG_SOURCE_DIR)
	cp -R $(PACKAGE_APP) $(PACKAGE_DMG_SOURCE_DIR)/
	create-dmg \
		--volname "BlueGull AQI" \
		--volicon $(PACKAGE_BUILD_DIR)/BluegullAQI.icns \
		--background $(MAC_APP_DIR)/branding/dmg-background.png \
		--window-size $(DMG_WINDOW_W) $(DMG_WINDOW_H) \
		--icon-size $(DMG_ICON_SIZE) \
		--icon "BluegullAQI.app" $(DMG_ICON_X) $(DMG_ICON_Y) \
		--hide-extension "BluegullAQI.app" \
		--app-drop-link $(DMG_APPLINK_X) $(DMG_APPLINK_Y) \
		--no-internet-enable \
		--overwrite \
		$(PACKAGE_BUILD_DIR)/BluegullAQI.dmg \
		$(PACKAGE_DMG_SOURCE_DIR)
	@echo "Packaged, notarized DMG at $(PACKAGE_BUILD_DIR)/BluegullAQI.dmg"
