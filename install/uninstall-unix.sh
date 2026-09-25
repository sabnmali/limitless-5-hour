#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# No 5-Hour Limit - removes the scheduler entry on macOS / Linux.
# config.env, logs/ and state/ are left untouched.
# ---------------------------------------------------------------------------
set -uo pipefail

LABEL="com.no5hourlimit.keepalive"

if [ "$(uname -s)" = "Darwin" ]; then
    PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
    if [ -f "$PLIST" ]; then
        launchctl unload "$PLIST" 2>/dev/null || true
        rm -f "$PLIST"
        echo "  LaunchAgent removed: $PLIST"
    else
        echo "  No LaunchAgent installed - nothing to do."
    fi
else
    if crontab -l 2>/dev/null | grep -q 'no-5-hour-limit'; then
        crontab -l 2>/dev/null | grep -v 'no-5-hour-limit' | crontab -
        echo "  crontab entry removed."
    else
        echo "  No crontab entry found - nothing to do."
    fi
fi

echo "  Your config.env, logs/ and state/ were left untouched."
