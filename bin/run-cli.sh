# Sourced by keepalive.sh. macOS has no GNU timeout, so use a watchdog.
run_bounded_cli() (
    # Give the CLI its own process group so timeout also stops its children.
    set -m
    local child watcher rc
    "$@" &
    child=$!
    (
        sleep 120
        kill -TERM -- "-$child" 2>/dev/null || exit 0
        sleep 5
        kill -KILL -- "-$child" 2>/dev/null || true
    ) >/dev/null 2>&1 &
    watcher=$!
    trap 'kill -- "-$child" "-$watcher" 2>/dev/null || true' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    wait "$child"; rc=$?
    kill -- "-$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    trap - EXIT
    return "$rc"
)
