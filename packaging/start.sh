#!/usr/bin/env bash
#
# Launch wacomd in the background, detached from the current terminal.
# Inherits the Accessibility / Input Monitoring permissions from the
# parent terminal app (Terminal.app, iTerm, …), so you don't need to
# grant them again to wacomd itself.
#
# After a reboot, just open a terminal and run :
#     ./packaging/start.sh
#
# To stop the daemon :
#     pkill -TERM -f '.build/release/wacomd'

set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="$REPO_DIR/.build/release/wacomd"

if [ ! -x "$BINARY" ]; then
    echo "wacomd release binary not found. Build it first:"
    echo "    cd $REPO_DIR && swift build -c release"
    exit 1
fi

# Kill any previous instance so we don't end up with duplicates fighting
# over the same HID device.
pkill -TERM -f '.build/release/wacomd' 2>/dev/null || true
sleep 1

nohup "$BINARY" > /tmp/wacomd.log 2>&1 &
disown

sleep 1
PID=$(pgrep -f '.build/release/wacomd' | head -1 || true)
if [ -n "$PID" ]; then
    echo "✓ wacomd running, PID $PID"
    echo "  log : /tmp/wacomd.log"
    tail -5 /tmp/wacomd.log
else
    echo "✗ wacomd failed to start. Check /tmp/wacomd.log :"
    tail -20 /tmp/wacomd.log
    exit 1
fi
