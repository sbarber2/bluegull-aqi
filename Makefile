# Repo-root test orchestration (bluegull-aqi-mtm.13), following Plant-
# Tracer's Makefile idiom: everything runnable from a bash command line, no
# Xcode GUI required. `service/Makefile` already covers the Python side in
# detail (poetry, DynamoDB Local, SAM); this delegates to it rather than
# duplicating it.
.PHONY: test test-swift test-ui test-service snapshots record-snapshots install uninstall \
        service-deploy service-delete service-enable service-disable

MAC_APP_DIR := mac-app
SERVICE_DIR := service
SNAPSHOT_SCRATCH_DIR := /tmp/bluegull-widget-snapshots

# Everything except test-ui -- see that target's own comment for why it's
# not part of the default run.
test: test-swift test-service

# Full BluegullAQI scheme (container app + widget extension) plus the
# BluegullAQIKit Swift package (small/medium/large widget layouts,
# snapshot regression tests, and everything else in BluegullAQIKitTests /
# BluegullAQIWidgetViewsTests) -- unsigned, so this needs no Apple
# Developer account or real device.
test-swift:
	cd $(MAC_APP_DIR) && xcodegen generate
	cd $(MAC_APP_DIR) && xcodebuild build -scheme BluegullAQI -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
	cd $(MAC_APP_DIR) && xcodebuild test -scheme BluegullAQI -destination 'platform=macOS' -only-testing:BluegullAQITests CODE_SIGNING_ALLOWED=NO
	cd $(MAC_APP_DIR)/BluegullAQIKit && swift test

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
# mac-app/BluegullAQIKit/Tests/BluegullAQIWidgetViewsTests/__Snapshots__/
# before committing it. Recording itself always reports failures (that's
# how it flags "these are new, go look at them," not a real problem) --
# the `|| true` keeps that from failing the make invocation.
record-snapshots:
	cd $(MAC_APP_DIR)/BluegullAQIKit && RECORD_SNAPSHOTS=1 swift test --filter BluegullAQIWidgetSnapshotTests || true
	@echo "Golden images re-recorded -- review the diff before committing."

# Real signed build (NOT CODE_SIGNING_ALLOWED=NO like test-swift -- App
# Sandbox needs an actual signature to launch at all), then launches the
# result -- the command-line equivalent of Xcode's own Cmd+R. See
# doc/DEVINSTALL.md "Install / run". Needs Xcode signed into the Apple ID
# that registered the solutions.bluegull.aqi bundle IDs/App Group
# (bluegull-aqi-8ef.5); if signing fails, open the project in Xcode once to
# resolve/select the team, or pass DEVELOPMENT_TEAM=XXXXXXXXXX here.
install:
	cd $(MAC_APP_DIR) && xcodegen generate
	cd $(MAC_APP_DIR) && xcodebuild build -scheme BluegullAQI -configuration Debug -destination 'platform=macOS' -allowProvisioningUpdates
	@cd $(MAC_APP_DIR) && \
	app_path=$$(xcodebuild -scheme BluegullAQI -configuration Debug -showBuildSettings -json 2>/dev/null \
		| python3 -c "import json,sys; d=json.load(sys.stdin); s=next(e for e in d if e['target']=='BluegullAQI')['buildSettings']; print(s['BUILT_PRODUCTS_DIR'] + '/' + s['FULL_PRODUCT_NAME'])") && \
	echo "Launching $$app_path" && \
	open "$$app_path"

# Reverses `install` (or any prior Xcode Cmd+R run) -- see doc/DEVINSTALL.md
# "Uninstall (leave no trace)" for what each step corresponds to. Two
# things this can't do: reliably clear the Keychain item (`security`'s CLI
# doesn't consistently target iCloud-synchronizable items the way
# SecItemAdd's kSecAttrSynchronizable does -- clear it from the app's own
# Settings before running this, or verify in Keychain Access.app after),
# and remove a widget placed on the desktop (no CLI for that).
uninstall:
	-pkill -x BluegullAQI
	rm -rf ~/Library/Developer/Xcode/DerivedData/BluegullAQI-*
	-security delete-generic-password -s solutions.bluegull.aqi.airnow-api-key -a airnow-api-key >/dev/null 2>&1
	-defaults delete solutions.bluegull.aqi >/dev/null 2>&1
	rm -rf ~/Library/Group\ Containers/group.solutions.bluegull.aqi
	tccutil reset Location solutions.bluegull.aqi
	@echo "Done. Verify the AirNow key is actually gone via Keychain Access.app (see comment above)."
	@echo "If you placed the widget on your desktop, remove it manually (right-click > Remove Widget)."
