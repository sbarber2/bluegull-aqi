#!/bin/bash
#
# Uninstall BlueGull AQI -- removes the app and every trace of its data
# from this Mac: the app bundle itself, its sandboxed containers (app +
# widget extension), the shared App Group data (cached readings, pinned
# locations, settings), the AirNow API key in Keychain, and LaunchServices/
# window-state/crash-log leftovers.
#
# Ships in the release DMG (mac-app/scripts/uninstall.command is the
# source of truth; `make app-package` copies it in) so a user can run this
# without checking out the repo. Double-clicking a `.command` file from
# Finder opens Terminal and runs it -- the standard macOS convention for a
# script meant to be run by a non-technical user, unlike a plain `.sh`
# (which Finder would just open in a text editor).
#
# Deliberately NOT `set -e`: almost every step here is "remove this path if
# it exists" -- a missing path is the expected, common case (e.g. a user
# who never enabled Direct mode has no Keychain item to delete), not a
# fatal error. Each step reports its own outcome and the script always
# continues to the next one.

set -u

APP_BUNDLE_ID="solutions.bluegull.aqi"
WIDGET_BUNDLE_ID="solutions.bluegull.aqi.widget"
# The background updater that keeps "Current Location" fresh while the app
# isn't running (bluegull-aqi-hib epic). A real shipped target as of the
# hib work -- it lives inside the app bundle but is its OWN sandboxed
# bundle id, so it has its own container that removing the app's does not
# touch.
HELPER_BUNDLE_ID="solutions.bluegull.aqi.locationhelper"
# A DIFFERENT, dead identifier from the 2026-08-12 feasibility spike, which
# has shown up on at least one dev machine. Never shipped; the real helper
# above deliberately uses a fresh id because the spike's locationd grant
# could not be removed (tccutil fails -10814). Harmless to clean up, and a
# no-op on any normal install.
STRAY_HELPER_BUNDLE_ID="solutions.bluegull.aqi.helper"
APP_GROUP_ID="group.solutions.bluegull.aqi"
KEYCHAIN_SERVICE="solutions.bluegull.aqi.airnow-api-key"
PROCESS_NAME="BluegullAQI"

BOLD=$(tput bold 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)

removed_anything=0

say() { printf '%s\n' "$1"; }
heading() { printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"; }

remove_path() {
    local path="$1"
    if [ -e "$path" ] || [ -L "$path" ]; then
        rm -rf "$path"
        say "  Removed: $path"
        removed_anything=1
    else
        say "  Not present: $path"
    fi
}

heading "BlueGull AQI Uninstaller"
say "This will remove BlueGull AQI and all of its data from this Mac:"
say "  - The app itself (and the widget extension inside it)"
say "  - All saved settings, pinned locations, and cached AQI readings"
say "  - Your saved AirNow API key (Direct mode), if any, from Keychain"
say "  - The background updater that keeps your current location up to date"
say ""
say "This cannot be undone."
say ""
if [ "${1:-}" != "-y" ] && [ "${1:-}" != "--force" ]; then
    printf "Continue? [y/N] "
    read -r reply
    case "$reply" in
        [yY]|[yY][eE][sS]) ;;
        *) say "Cancelled -- nothing was removed."; exit 0 ;;
    esac
fi

heading "Stopping BlueGull AQI"
if pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
    pkill -x "$PROCESS_NAME" 2>/dev/null || true
    say "  Stopped the running app."
else
    say "  Not currently running."
fi

heading "Locating the app"
# `mdfind` first -- the app may not be in /Applications (some users keep
# it in ~/Applications, or wherever they dragged it) -- falling back to
# the conventional install path if Spotlight has nothing indexed (e.g.
# Spotlight indexing is off, or this runs immediately after install
# before mdimport has caught up).
app_path=$(mdfind "kMDItemCFBundleIdentifier == '$APP_BUNDLE_ID'" 2>/dev/null | head -1)
if [ -z "$app_path" ] && [ -d "/Applications/BluegullAQI.app" ]; then
    app_path="/Applications/BluegullAQI.app"
fi

if [ -n "$app_path" ]; then
    say "  Found: $app_path"

    heading "Turning off background updates"
    # MUST run before the app bundle is deleted, a few steps below.
    # SMAppService resolves the agent relative to the bundle it is called
    # from, so this only works from inside the app that is about to be
    # removed -- afterwards there is nothing left to unregister with, and
    # the row in System Settings > Login Items & Extensions survives
    # pointing at a bundle that no longer exists. `launchctl bootout` is
    # not a substitute: it stops a running job and leaves that record
    # behind (measured during the bluegull-aqi-hib.10 spike, which is
    # exactly how a thing can look uninstalled and still be registered).
    helper_exec="$app_path/Contents/MacOS/$PROCESS_NAME"
    if [ -x "$helper_exec" ]; then
        BLUEGULL_HELPER_ACTION=unregister "$helper_exec" 2>&1 | sed 's/^/  /' \
            || say "  Couldn't turn it off automatically (non-fatal) -- check Login Items & Extensions below."
        removed_anything=1
    else
        say "  App executable not found -- skipping."
    fi

    heading "Unregistering from LaunchServices"
    /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -u "$app_path" 2>/dev/null \
        && say "  Unregistered." \
        || say "  Couldn't unregister (non-fatal, continuing)."
    heading "Removing the app"
    remove_path "$app_path"
else
    say "  Not found -- skipping app removal (it may already be gone, or Spotlight hasn't indexed it)."
fi

heading "Removing app data"
# Removing the app's own container removes its whole
# Data/Library/Preferences/$APP_BUNDLE_ID.plist too -- which is where
# UserDefaults.standard actually lives for a sandboxed app, and so is
# also where AppKit's own window-frame autosave entries ("NSWindow Frame
# settings", "NSWindow Frame widget-detail") are stored. Confirmed
# directly, not assumed: this is the exact same location manually cleared
# by hand with `defaults delete`/`plutil` while chasing the stale-
# saved-frame bug during the Settings panel redesign (bluegull-aqi-a22) --
# so yes, this also fixes a stuck oversized/off-screen Settings window
# left over from a version installed before that redesign, the same way
# it was fixed by hand during development.
remove_path "$HOME/Library/Containers/$APP_BUNDLE_ID"
remove_path "$HOME/Library/Containers/$WIDGET_BUNDLE_ID"
remove_path "$HOME/Library/Containers/$HELPER_BUNDLE_ID"
remove_path "$HOME/Library/Containers/$STRAY_HELPER_BUNDLE_ID"
remove_path "$HOME/Library/Group Containers/$APP_GROUP_ID"
remove_path "$HOME/Library/Saved Application State/$APP_BUNDLE_ID.savedState"

heading "Removing crash/diagnostic logs"
found_logs=0
for f in "$HOME"/Library/Logs/DiagnosticReports/BluegullAQI*; do
    if [ -e "$f" ]; then
        rm -f "$f"
        say "  Removed: $f"
        found_logs=1
        removed_anything=1
    fi
done
[ "$found_logs" -eq 0 ] && say "  None found."

heading "Removing your saved AirNow API key from Keychain"
# `security` here runs as the interactive user, not the app -- it may show
# a one-time system prompt asking to confirm access to this Keychain item;
# that's expected and safe to allow.
if security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then
    say "  Removed."
    removed_anything=1
else
    say "  None found (or already removed)."
fi

heading "Login items"
# The background updater was unregistered above, while the bundle still
# existed. What remains here is the SEPARATE "Launch BlueGull AQI at login"
# setting (bluegull-aqi-fvt, SMAppService.mainApp) -- a different
# registration this script cannot remove the same way, because by now the
# app it points at is gone.
say "  Background updates were turned off above."
say ""
say "  If you also had \"Launch BlueGull AQI at login\" turned on in Settings,"
say "  macOS may still list it in System Settings > General > Login Items"
say "  & Extensions. Opening that pane now so you can remove it if present."
open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension" 2>/dev/null || true

heading "Done"
if [ "$removed_anything" -eq 1 ]; then
    say "BlueGull AQI has been uninstalled."
else
    say "Nothing was found to remove -- BlueGull AQI doesn't appear to be installed on this Mac."
fi
say ""
say "Press Return to close this window."
read -r _
