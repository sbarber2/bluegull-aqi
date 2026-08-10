# Repo-root test orchestration (bluegull-aqi-mtm.13), following Plant-
# Tracer's Makefile idiom: everything runnable from a bash command line, no
# Xcode GUI required. `service/Makefile` already covers the Python side in
# detail (poetry, DynamoDB Local, SAM); this delegates to it rather than
# duplicating it.
.PHONY: test test-swift test-snapshots test-ui test-service snapshots record-snapshots \
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
# Name of the one-time `xcrun notarytool store-credentials` keychain
# profile -- see doc/DEVINSTALL.md "Package for ad-hoc distribution" for
# setup. Not a secret itself (just a label); the credentials it points to
# live in the login keychain, never in this repo.
NOTARY_PROFILE := bluegull-aqi-notary

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
	cd $(MAC_APP_DIR) && xcodebuild build -scheme BluegullAQI -configuration Debug -destination 'platform=macOS' -allowProvisioningUpdates

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

# One-off ad-hoc distribution outside the Mac App Store (bluegull-aqi-do1)
# -- e.g. sending a signed build to a friend to try out. Distinct from the
# App Store submission path (bluegull-aqi-fw4 epic): this never touches App
# Store Connect. Archives Release, exports with the Developer ID method
# (mac-app/ExportOptions.plist), notarizes, staples the ticket, and wraps
# the result in a DMG under $(PACKAGE_BUILD_DIR) (gitignored scratch dir,
# wiped and rebuilt from scratch every run).
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
	cd $(MAC_APP_DIR) && xcodegen generate
	rm -rf $(PACKAGE_BUILD_DIR)
	mkdir -p $(PACKAGE_BUILD_DIR)
	cd $(MAC_APP_DIR) && xcodebuild archive -scheme BluegullAQI -configuration Release \
		-archivePath build/BluegullAQI.xcarchive -allowProvisioningUpdates
	cd $(MAC_APP_DIR) && xcodebuild -exportArchive -archivePath build/BluegullAQI.xcarchive \
		-exportPath build/export -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates
	ditto -c -k --keepParent $(PACKAGE_APP) $(PACKAGE_BUILD_DIR)/BluegullAQI.zip
	xcrun notarytool submit $(PACKAGE_BUILD_DIR)/BluegullAQI.zip \
		--keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(PACKAGE_APP)
	hdiutil create -volname "BlueGull AQI" -srcfolder $(PACKAGE_APP) -ov -format UDZO \
		$(PACKAGE_BUILD_DIR)/BluegullAQI.dmg
	@echo "Packaged, notarized DMG at $(PACKAGE_BUILD_DIR)/BluegullAQI.dmg"
