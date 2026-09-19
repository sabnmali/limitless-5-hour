# Sourced by keepalive.sh. macOS has no GNU timeout, so use a watchdog.
run_bounded_cli() (
    # Give the CLI its own process group so timeout also stops its children.
    set -m
    local child watcher rc timeout_marker
    timeout_marker="${TMPDIR:-/tmp}/l5h-timeout-$$-$RANDOM"
    rm -f "$timeout_marker"
    "$@" &
    child=$!
    (
        sleep 120
        # A CLI may handle TERM and exit 0. Record that the watchdog fired so
        # such a graceful shutdown can never be mistaken for provider success.
        : > "$timeout_marker"
        kill -TERM -- "-$child" 2>/dev/null || exit 0
        sleep 5
        kill -KILL -- "-$child" 2>/dev/null || true
    ) >/dev/null 2>&1 &
    watcher=$!
    trap 'kill -- "-$child" "-$watcher" 2>/dev/null || true; rm -f "$timeout_marker"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    wait "$child"; rc=$?
    kill -- "-$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    [ ! -e "$timeout_marker" ] || rc=124
    rm -f "$timeout_marker"
    trap - EXIT
    return "$rc"
)
