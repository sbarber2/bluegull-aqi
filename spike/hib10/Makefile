# bluegull-aqi-hib.10 spike. See README.md for what this is measuring.

SHELL := /bin/bash
APP_NAME := Hib10Container
BUILD := build
PRODUCT := $(BUILD)/Build/Products/Release/$(APP_NAME).app
INSTALLED := /Applications/$(APP_NAME).app
IDENTITY := Developer ID Application: Steven Barber (G5DWPBWHQ5)
SUBSYSTEM := solutions.bluegull.hib10

.PHONY: build install uninstall logs logs-live status clean

# Signed by hand rather than by Xcode. Xcode's ProcessProductPackaging step
# filters the entitlements file against a provisioning profile, and manual
# Developer ID signing has no profile -- so it silently dropped
# com.apple.security.app-sandbox and shipped only get-task-allow (confirmed by
# inspecting the first build). A sandboxed helper is the whole point of the
# fidelity here: an unsandboxed spike would prove something the App Store
# build could never rely on. codesign applies what it is given, so it is used
# directly. Inside-out order is required -- hib10-agent is nested code and has
# to be sealed before the outer bundle is signed over it.
build:
	xcodegen generate
	xcodebuild build -scheme $(APP_NAME) -configuration Release \
		-destination 'platform=macOS' -derivedDataPath $(BUILD) \
		CODE_SIGNING_ALLOWED=NO | tail -3
	codesign --force --options runtime --timestamp \
		--entitlements Agent/Agent.entitlements \
		--sign "$(IDENTITY)" "$(PRODUCT)/Contents/MacOS/hib10-agent"
	codesign --force --options runtime --timestamp \
		--entitlements Container/Container.entitlements \
		--sign "$(IDENTITY)" "$(PRODUCT)"
	@echo "--- agent entitlements (must include app-sandbox) ---"
	@codesign -d --entitlements :- "$(PRODUCT)/Contents/MacOS/hib10-agent" 2>/dev/null | plutil -p -
	@echo "--- agent signing identifier (must differ from the container's) ---"
	@codesign -dv "$(PRODUCT)/Contents/MacOS/hib10-agent" 2>&1 | grep '^Identifier'
	@codesign -dv "$(PRODUCT)" 2>&1 | grep '^Identifier'
	@codesign --verify --deep --strict --verbose=2 "$(PRODUCT)" 2>&1 | tail -2

# Installed to /Applications, not run from DerivedData, and this matters:
# SMAppService records where the app was at registration time, and a
# DerivedData path changes whenever the checkout path does -- the exact trap
# already documented in bluegull-aqi-mtm.9 for widget registration. The reboot
# test needs a path that will still be there afterwards.
install: build
	@if [ -e "$(INSTALLED)" ]; then \
		echo "Removing previous $(INSTALLED)"; rm -rf "$(INSTALLED)"; fi
	cp -R "$(PRODUCT)" "$(INSTALLED)"
	@echo "Installed to $(INSTALLED)"
	@echo "Now: open '$(INSTALLED)' and use the Register buttons."

# Leaves no trace: unregister via the app first if it is still installed,
# then remove the bundle. Any leftover Login Items row is stale UI, not a
# running agent, and clears on the next login.
uninstall:
	-launchctl bootout gui/$$(id -u)/$(SUBSYSTEM).checkin 2>/dev/null
	-launchctl bootout gui/$$(id -u)/$(SUBSYSTEM).register 2>/dev/null
	rm -rf "$(INSTALLED)"
	@echo "Removed. Confirm System Settings > General > Login Items & Extensions has no hib.10 row."

# .notice level, so this survives a reboot -- the measurement that matters
# most here is one that has to be read back after the machine restarts.
logs:
	@log show --last 6h --style compact \
		--predicate 'subsystem == "$(SUBSYSTEM)"' 2>/dev/null || echo "(nothing yet)"

logs-live:
	log stream --style compact --predicate 'subsystem == "$(SUBSYSTEM)"'

status:
	@echo "--- launchd jobs ---"
	@launchctl list | grep -i hib10 || echo "(no hib10 job loaded)"
	@echo "--- login items records ---"
	@sfltool dumpbtm 2>/dev/null | grep -i -A3 hib10 || echo "(sfltool needs sudo; check System Settings instead)"

clean:
	rm -rf $(BUILD) Hib10Spike.xcodeproj
