#!/usr/bin/env bash
#
# Re-enable the official Wacom driver daemons (undo `disable-wacom-driver.sh`).
#
# Use this if you want to switch back to Wacom's stack for a different tablet
# that Wacom still supports.

set -e

echo "Re-enabling Wacom driver daemons…"

UID_NUM=$(id -u)
for plist in /Library/LaunchAgents/com.wacom.*.plist; do
    [ -e "$plist" ] || continue
    label=$(basename "$plist" .plist)
    echo "  bootstrap $label"
    launchctl bootstrap gui/$UID_NUM "$plist" 2>/dev/null || true
    launchctl enable    gui/$UID_NUM/$label  2>/dev/null || true
done

echo
echo "✅ Done. You may want to stop wacomd if you don't need it anymore:"
echo "   launchctl bootout gui/$UID_NUM/com.local.wacomd"
