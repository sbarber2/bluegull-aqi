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
		--entitlements LocProbe/LocProbe.entitlements \
		--sign "$(IDENTITY)" "$(PRODUCT)/Contents/Library/LoginItems/Hib10LocProbe.app"
	codesign --force --options runtime --timestamp \
		--entitlements Agent/Agent.entitlements \
		--sign "$(IDENTITY)" "$(PRODUCT)/Contents/MacOS/hib10-agent"
	codesign --force --options runtime --timestamp \
		--entitlements Container/Container.entitlements \
		--sign "$(IDENTITY)" "$(PRODUCT)"
	@echo "--- agent entitlements (must include app-sandbox) ---"
	@codesign -d --entitlements :- "$(PRODUCT)/Contents/MacOS/hib10-agent" 2>/dev/null | plutil -p -
	@echo "--- probe entitlements (must include app-sandbox AND location) ---"
	@codesign -d --entitlements :- "$(PRODUCT)/Contents/Library/LoginItems/Hib10LocProbe.app" 2>/dev/null | plutil -p -
	@echo "--- agent signing identifier (must differ from the container's) ---"
	@codesign -dv "$(PRODUCT)/Contents/MacOS/hib10-agent" 2>&1 | grep '^Identifier'
	@codesign -dv "$(PRODUCT)/Contents/Library/LoginItems/Hib10LocProbe.app" 2>&1 | grep '^Identifier'
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

# Leaves no trace. Order matters: SMAppService.unregister() must run FROM the
# installed bundle, because that is what removes the Background Task Management
# record behind the Login Items row -- deleting the .app first would strand it.
# `launchctl bootout` afterwards only stops a still-running process; on its own
# it does not unregister anything.
#
# Covers all four agents. The earlier version of this target listed only
# checkin and register, because machsvc and locprobe were added later -- an
# uninstall that silently leaves agents behind is worse than no uninstall.
uninstall:
	-@if [ -x "$(INSTALLED)/Contents/MacOS/$(APP_NAME)" ]; then \
		HIB10_ACTION=unregister "$(INSTALLED)/Contents/MacOS/$(APP_NAME)"; \
		HIB10_ACTION=unregister-machsvc "$(INSTALLED)/Contents/MacOS/$(APP_NAME)"; \
		HIB10_ACTION=unregister-probe "$(INSTALLED)/Contents/MacOS/$(APP_NAME)"; \
	else echo "(bundle already gone -- booting out any strays)"; fi
	-@for j in checkin register machsvc locprobe; do \
		launchctl bootout gui/$$(id -u)/$(SUBSYSTEM).$$j 2>/dev/null; done
	rm -rf "$(INSTALLED)"
	@echo "--- remaining hib10 jobs (want: none) ---"
	@launchctl list | grep -i hib10 || echo "none"
	@echo "--- remaining hib10 processes (want: none) ---"
	@pgrep -fl "hib10-agent|Hib10" || echo "none"
	@echo "Confirm System Settings > General > Login Items & Extensions has no hib.10 row."

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
