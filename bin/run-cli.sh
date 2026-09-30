# Sourced by keepalive.sh. macOS has no GNU timeout, so use a watchdog.
run_bounded_cli() (
    # Give the CLI its own process group so timeout also stops its children.
    set -m
    local child watcher rc work
    # A private, unguessable directory: another local user cannot pre-create
    # the timeout marker and make every ping look like a timeout.
    work="$(mktemp -d "${TMPDIR:-/tmp}/l5h.XXXXXXXX")" || return 1
    # Output goes to a file, not the caller's pipe. A process the CLI leaves
    # behind outside its group could otherwise hold the pipe open and make
    # the caller's $(...) wait forever.
    "$@" > "$work/out" 2>&1 &
    child=$!
    (
        sleep 120
        # A CLI may handle TERM and exit 0. Record that the watchdog fired so
        # such a graceful shutdown can never be mistaken for provider success.
        : > "$work/timeout"
        kill -TERM -- "-$child" 2>/dev/null || exit 0
        sleep 5
        kill -KILL -- "-$child" 2>/dev/null || true
    ) >/dev/null 2>&1 &
    watcher=$!
    trap 'kill -- "-$child" "-$watcher" 2>/dev/null || true; rm -rf "$work"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    wait "$child"; rc=$?
    kill -- "-$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    [ ! -e "$work/timeout" ] || rc=124
    cat "$work/out" 2>/dev/null
    rm -rf "$work"
    trap - EXIT
    return "$rc"
)
