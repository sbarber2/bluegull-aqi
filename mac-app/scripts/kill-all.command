#!/bin/bash
#
# Force-quit every BlueGull AQI process -- the main app and the widget
# extension (BluegullAQIWidget.appex, which the desktop widget host runs
# as a separate process and doesn't always exit when the main app does).
#
# Non-destructive -- this only stops running processes, it doesn't touch
# any saved data. Safe to run any time; the app and widgets come back
# normally the next time they're opened. Handy when something looks stuck
# (a widget showing stale data, the menu bar icon unresponsive) and a
# clean relaunch is the easiest fix.
#
# Ships in the release DMG (mac-app/scripts/kill-all.command is the
# source of truth; `make app-package` copies it in) -- same double-click-
# from-Finder convention as mac-app/scripts/uninstall.command (a `.command`
# file, not `.sh`, so Finder runs it in Terminal instead of opening it in
# a text editor).

set -u

echo "Stopping BlueGull AQI..."

found_anything=0

if pgrep -x "BluegullAQI" >/dev/null 2>&1; then
    pkill -x "BluegullAQI"
    echo "  Stopped the main app."
    found_anything=1
else
    echo "  Main app not running."
fi

if pgrep -f "BluegullAQIWidget.appex" >/dev/null 2>&1; then
    pkill -f "BluegullAQIWidget.appex"
    echo "  Stopped the widget extension."
    found_anything=1
else
    echo "  Widget extension not running."
fi

echo ""
if [ "$found_anything" -eq 1 ]; then
    echo "Done. Reopen BlueGull AQI (or its widgets) normally whenever you're ready."
else
    echo "Nothing was running."
fi
echo ""
echo "Press Return to close this window."
read -r _
