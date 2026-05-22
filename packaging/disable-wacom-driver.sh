#!/usr/bin/env bash
#
# Disable the official Wacom driver daemons.
#
# Why this matters
# ----------------
# Even when Wacom's driver no longer supports your tablet (e.g. on PTH-451 on
# macOS 26 Tahoe), the installer still puts a `TabletEvents` framework in
# place and runs several background daemons that intercept tablet events at
# the system level. Pressure-aware apps (Photoshop, Affinity Photo,
# Procreate, …) prefer that pipeline over the standard NSEvent tablet API,
# so they receive zero pressure and your `wacomd` events get partially
# ignored.
#
# This script unloads the Wacom LaunchAgents and kills the running daemons.
# The Wacom drivers stay on disk and can be re-enabled with the companion
# `restore-wacom-driver.sh` script.
#
# Safe : reversible, doesn't delete any Wacom files, doesn't require sudo
# (only user-level LaunchAgents are touched).

set -e

echo "Disabling Wacom driver daemons…"

UID_NUM=$(id -u)
for plist in /Library/LaunchAgents/com.wacom.*.plist; do
    [ -e "$plist" ] || continue
    label=$(basename "$plist" .plist)
    echo "  bootout $label"
    launchctl bootout gui/$UID_NUM/$label 2>/dev/null || true
done

echo "Killing residual Wacom processes…"
pkill -f 'WacomTabletDriver|WacomTouchDriver|TabletDriver|com.wacom.IOManager|com.wacom.DataStoreMgr' 2>/dev/null || true
sleep 1

remaining=$(ps aux | grep -iE 'wacom|tablet' | grep -v grep | grep -v '/Users/.*wacomd' | grep -v 'UpdateHelper' || true)
if [ -n "$remaining" ]; then
    echo "⚠️  Some Wacom processes are still running (not critical, they don't intercept events):"
    echo "$remaining"
fi

echo
echo "✅ Done. Restart your drawing app (Cmd-Q + reopen) so it reloads without"
echo "   the Wacom TabletEvents framework."
echo
echo "   To restore the Wacom driver later, run packaging/restore-wacom-driver.sh"
