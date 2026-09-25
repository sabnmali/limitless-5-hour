#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# No 5-Hour Limit - installer for macOS and Linux.
#
#   macOS : registers a LaunchAgent (survives sleep and logout properly)
#   Linux : adds a crontab entry
#
#   ./install/install-unix.sh              check every 15 minutes (default)
#   ./install/install-unix.sh --every 10   check every 10 minutes
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
KEEPALIVE="$REPO_ROOT/bin/keepalive.sh"

CHECK_MINUTES=15
LABEL="com.no5hourlimit.keepalive"

while [ $# -gt 0 ]; do
    case "$1" in
        --every) shift; CHECK_MINUTES="${1:-15}" ;;
        -h|--help) sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

case "$CHECK_MINUTES" in ''|*[!0-9]*) CHECK_MINUTES=15 ;; esac
[ "$CHECK_MINUTES" -ge 1 ] || CHECK_MINUTES=15
[ "$CHECK_MINUTES" -le 59 ] || CHECK_MINUTES=59
CHECK_MINUTES=$((10#$CHECK_MINUTES))

ok()   { printf '  OK  %s\n' "$*"; }
warn() { printf '  !   %s\n' "$*"; }
step() { printf '  ->  %s\n' "$*"; }

echo
echo "  No 5-Hour Limit - installer"
echo "  ============================================================"
echo

[ -f "$KEEPALIVE" ] || { echo "Cannot find $KEEPALIVE - run this from inside the repository." >&2; exit 1; }
chmod +x "$KEEPALIVE" "$SCRIPT_DIR"/*.sh 2>/dev/null || true
mkdir -p "$REPO_ROOT/logs" "$REPO_ROOT/state"

# --- 1. config -------------------------------------------------------------
if [ ! -f "$REPO_ROOT/config.env" ]; then
    cp "$REPO_ROOT/config.example.env" "$REPO_ROOT/config.env"
    ok "created config.env from the example"
else
    ok "config.env already exists - leaving it alone"
fi

# --- 2. dependencies + pin the absolute CLI paths into config.env ----------
# cron and launchd run with a stripped-down PATH, so "claude" alone is often
# not resolvable there. Record the full path now.
set_config_value() {
    local key="$1" value="$2" cfg="$REPO_ROOT/config.env" tmp
    tmp="$(mktemp)"
    if grep -qE "^[[:space:]]*$key[[:space:]]*=" "$cfg"; then
        awk -v k="$key" -v v="$value" \
            '{ if ($0 ~ "^[[:space:]]*"k"[[:space:]]*=") print k"="v; else print }' \
            "$cfg" > "$tmp"
    else
        cat "$cfg" > "$tmp"
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
    fi
    mv "$tmp" "$cfg"
}

if command -v claude >/dev/null 2>&1; then
    set_config_value CLAUDE_BIN "$(command -v claude)"
    ok "claude CLI found: $(command -v claude)"
    if claude auth status 2>/dev/null | grep -q '"loggedIn"[[:space:]]*:[[:space:]]*true'; then
        ok "claude CLI is logged in"
    else
        warn "claude CLI is NOT logged in. Run this once in a terminal:"
        echo "        claude auth login"
    fi
else
    warn "claude CLI not found on PATH. Install it with:"
    echo "        npm install -g @anthropic-ai/claude-code"
fi

if command -v codex >/dev/null 2>&1; then
    set_config_value CODEX_BIN "$(command -v codex)"
    ok "codex CLI found: $(command -v codex)"
else
    step "codex CLI not found (only needed if you enable CODEX_ENABLED)"
fi

# --- 3. remember the path + install the Claude Code skill ------------------
printf '%s\n' "$REPO_ROOT" > "$HOME/.no-5-hour-limit-path"
ok "recorded the install path in ~/.no-5-hour-limit-path"

if [ -d "$REPO_ROOT/skill/no-5-hour-limit" ]; then
    mkdir -p "$HOME/.claude/skills/no-5-hour-limit"
    cp -R "$REPO_ROOT/skill/no-5-hour-limit/." "$HOME/.claude/skills/no-5-hour-limit/"
    ok 'Claude Code skill installed - just ask Claude "limitim ne durumda?"'
fi

# --- 4. scheduler ----------------------------------------------------------
# A path containing & or < is legal on disk but breaks the plist it is pasted
# into, so escape anything that is XML-significant.
xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
                           -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

if [ "$(uname -s)" = "Darwin" ]; then
    PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
    mkdir -p "$HOME/Library/LaunchAgents"

    launchctl unload "$PLIST" 2>/dev/null || true

    X_LABEL="$(xml_escape "$LABEL")"
    X_KEEPALIVE="$(xml_escape "$KEEPALIVE")"
    X_REPO_ROOT="$(xml_escape "$REPO_ROOT")"
    X_PATH="$(xml_escape "$PATH")"

    cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$X_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$X_KEEPALIVE</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$X_REPO_ROOT</string>
    <key>StartInterval</key>
    <integer>$((CHECK_MINUTES * 60))</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$X_REPO_ROOT/logs/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$X_REPO_ROOT/logs/launchd.err.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$X_PATH</string>
    </dict>
</dict>
</plist>
PLIST_EOF

    launchctl load "$PLIST"
    ok "LaunchAgent installed: $PLIST (checks every $CHECK_MINUTES minute(s))"
else
    # cron treats an unescaped % as end-of-command plus stdin, so a path
    # containing one would silently truncate the job.
    # Single-quote the shell path before cron's separate percent escaping.
    # Double quotes would execute dollar/backtick substitutions in a folder name.
    case "$KEEPALIVE" in *$'\n'*|*$'\r'*) echo 'Newlines in install paths are unsupported' >&2; exit 2 ;; esac
    CRON_KEEPALIVE="$(printf '%s' "$KEEPALIVE" | sed "s/'/'\\\\''/g" | sed 's/%/\\%/g')"
    CRON_LINE="*/$CHECK_MINUTES * * * * /bin/bash '$CRON_KEEPALIVE' >/dev/null 2>&1  # no-5-hour-limit"
    ( crontab -l 2>/dev/null | grep -v 'no-5-hour-limit' || true; echo "$CRON_LINE" ) | crontab -
    ok "crontab entry installed (checks every $CHECK_MINUTES minute(s))"
    step "$CRON_LINE"
fi

# --- 5. done ---------------------------------------------------------------
cat <<DONE_EOF

  Installed.

  Next steps
  ----------
   1. If the check above said "NOT logged in", run:  claude auth login
   2. Fire the first ping now:
        "$KEEPALIVE" --force
   3. Check on it any time:
        "$KEEPALIVE" --status

  To remove:  "$SCRIPT_DIR/uninstall-unix.sh"

DONE_EOF
