#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# No 5-Hour Limit - keeps AI CLI usage windows rolling (macOS / Linux).
#
# Sends a minimal "ping" prompt to the Claude CLI and/or the Codex CLI once the
# configured interval has elapsed since the last successful ping. This may
# start an idle usage window; it does not report actual provider reset times.
#
# The script is idempotent: it only pings when the interval has actually
# elapsed, so cron just needs to poke it every few minutes.
#
#   ./bin/keepalive.sh              run a due check (what cron calls)
#   ./bin/keepalive.sh --status     show last ping / window end / next ping
#   ./bin/keepalive.sh --force      ping now, ignoring interval + quiet hours
#   ./bin/keepalive.sh --dry-run    print the commands without running them
#   ./bin/keepalive.sh --due        list providers needing a ping; exit 3 if none
#   ./bin/keepalive.sh --enabled    list providers the config turns on
#   ./bin/keepalive.sh --config F   read settings from F instead of config.env
#
# A provider that answers "usage limit reached" is not a failure of this job:
# the retry is deferred (to the reset time the provider names, else one hour)
# and the run exits 0, so schedulers and CI do not report an error every poll.
#
# Env overrides: L5H_CONFIG (config file), L5H_STATE_FILE (state file).
# ---------------------------------------------------------------------------
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/run-cli.sh"
LOG_DIR="$REPO_ROOT/logs"
STATE_DIR="$REPO_ROOT/state"
# L5H_STATE_FILE / L5H_CONFIG let a caller (e.g. the GitHub Actions runner)
# point at a different state file and config without touching the local ones.
STATE_FILE="${L5H_STATE_FILE:-$STATE_DIR/state.env}"
WORK_DIR="$STATE_DIR/workdir"
CONFIG_PATH="${L5H_CONFIG:-$REPO_ROOT/config.env}"

DO_STATUS=0
DO_FORCE=0
DO_DRYRUN=0
DO_DUE=0
DO_ENABLED=0
CONFIG_REQUIRED=0

while [ $# -gt 0 ]; do
    case "$1" in
        --status)   DO_STATUS=1 ;;
        --force)    DO_FORCE=1 ;;
        --dry-run)  DO_DRYRUN=1 ;;
        --due)      DO_DUE=1 ;;
        --enabled)  DO_ENABLED=1 ;;
        --config)   [ $# -ge 2 ] || { echo '--config requires a path' >&2; exit 2; }; shift; CONFIG_PATH="$1"; CONFIG_REQUIRED=1 ;;
        -h|--help)  sed -n '2,26p'"${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

mkdir -p "$LOG_DIR" "$STATE_DIR" "$WORK_DIR" "$(dirname "$STATE_FILE")"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
INTERVAL_MINUTES=301
CLAUDE_ENABLED=true
CLAUDE_MODEL=haiku
CLAUDE_PROMPT=ok
CLAUDE_BIN=
CODEX_ENABLED=false
CODEX_MODEL=
CODEX_PROMPT=ok
CODEX_BIN=
CODEX_REASONING_EFFORT=low
LOG_RETENTION_DAYS=30
QUIET_HOURS=

# Keys a file is allowed to set. Everything else is ignored, so a tampered or
# careless config cannot reach into the script and reassign PATH, STATE_FILE,
# DO_FORCE or anything else it was never meant to touch.
CONFIG_KEYS="INTERVAL_MINUTES CLAUDE_ENABLED CLAUDE_MODEL CLAUDE_PROMPT CLAUDE_BIN CODEX_ENABLED CODEX_MODEL CODEX_PROMPT CODEX_BIN CODEX_REASONING_EFFORT LOG_RETENTION_DAYS QUIET_HOURS"
STATE_KEYS="CLAUDE_LAST CODEX_LAST CLAUDE_RETRY CODEX_RETRY"

load_kv_file() {
    # Reads KEY=VALUE lines without executing the file. $2 is the allowlist.
    local file="$1" allowed="$2" line key val
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        line="${line#$'\xef\xbb\xbf'}"
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in *=*) ;; *) continue ;; esac
        key="${line%%=*}"
        val="${line#*=}"
        key="$(printf '%s' "$key" | tr -d '[:space:]')"
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        val="${val%\"}"; val="${val#\"}"
        val="${val%\'}"; val="${val#\'}"
        case " $allowed " in
            *" $key "*) printf -v "$key" '%s' "$val" ;;
        esac
    done < "$file"
}

# A config path given on the command line has to exist. Falling back to the
# defaults there would silently enable Claude against the caller's intent.
if [ "$CONFIG_REQUIRED" -eq 1 ] && [ ! -f "$CONFIG_PATH" ]; then
    echo "config file not found: $CONFIG_PATH" >&2
    exit 2
fi

load_kv_file "$CONFIG_PATH" "$CONFIG_KEYS"

to_int() {
    # Normalises a decimal number. Without the 10# prefix, arithmetic reads a
    # leading-zero value as octal, so 0301 would silently become 193 - and 0308
    # would abort the script outright.
    local v="${1:-}"
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
    # 18 digits stays inside a signed 64-bit integer. It has to be well above
    # 10, because epoch seconds are 10 digits and this normalises those too.
    [ "${#v}" -le 18 ] || return 1
    printf '%s' "$((10#$v))"
}

INTERVAL_MINUTES="$(to_int "$INTERVAL_MINUTES")" || INTERVAL_MINUTES=301
# Keep interval arithmetic bounded and prevent sub-window polling.
[ "$INTERVAL_MINUTES" -ge 300 ] || INTERVAL_MINUTES=300
[ "$INTERVAL_MINUTES" -le 525600 ] || INTERVAL_MINUTES=525600

is_true() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        true|1|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
LOG_FILE="$LOG_DIR/keepalive-$(date +%Y-%m).log"

redact() { sed -E 's/[A-Za-z0-9_-]{24,}/[redacted]/g'; }

log() {
    local level="$1"; shift
    local line
    line="$(printf '[%s] %-5s %s' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$(printf '%s' "$level" | tr '[:lower:]' '[:upper:]')" "$(printf '%s' "$*" | redact)")"
    printf '%s\n' "$line" >> "$LOG_FILE"
    printf '%s\n' "$line"
}

prune_logs() {
    case "$LOG_RETENTION_DAYS" in ''|*[!0-9]*) return 0 ;; esac
    [ "$LOG_RETENTION_DAYS" -gt 0 ] || return 0
    find "$LOG_DIR" -maxdepth 1 -name 'keepalive-*.log' -type f \
        -mtime "+$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# State  (state.env holds e.g.  CLAUDE_LAST=1757075400 )
# ---------------------------------------------------------------------------
CLAUDE_LAST=0
CODEX_LAST=0
# Epoch second before which a provider whose quota ran out is not retried.
CLAUDE_RETRY=0
CODEX_RETRY=0
load_state() {
    load_kv_file "$STATE_FILE" "$STATE_KEYS"
    CLAUDE_LAST="$(to_int "$CLAUDE_LAST")"   || CLAUDE_LAST=0
    CODEX_LAST="$(to_int "$CODEX_LAST")"     || CODEX_LAST=0
    CLAUDE_RETRY="$(to_int "$CLAUDE_RETRY")" || CLAUDE_RETRY=0
    CODEX_RETRY="$(to_int "$CODEX_RETRY")"   || CODEX_RETRY=0
}
load_state

save_state() {
    # Write to a temporary file in the same directory and rename it into place,
    # so an interrupted run cannot leave a half-written state behind. A failure
    # here has to be loud: a lost timestamp means the next run pings again.
    local tmp="$STATE_FILE.tmp.$$"
    [ ! -d "$STATE_FILE" ] || { log error 'state path is a directory'; return 1; }
    {
        echo "# No 5-Hour Limit state - epoch seconds of the last successful ping"
        echo "CLAUDE_LAST=$CLAUDE_LAST"
        echo "CODEX_LAST=$CODEX_LAST"
        echo "CLAUDE_RETRY=$CLAUDE_RETRY"
        echo "CODEX_RETRY=$CODEX_RETRY"
    } > "$tmp" || { rm -f "$tmp"; log error "could not write state to $STATE_FILE"; return 1; }
    mv -f "$tmp" "$STATE_FILE" || { rm -f "$tmp"; log error "could not replace $STATE_FILE"; return 1; }
    return 0
}

# Two runs starting at once would both read the old timestamp and both ping.
# On Linux cron that happens on its own as soon as one ping outlives the poll
# interval. mkdir is the portable atomic primitive; flock is not on macOS.
LOCK_DIR="$STATE_DIR/.lock"
acquire_lock() {
    local tries=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        # Only reclaim a dead owner. Age alone can evict a still-running CLI.
        local owner=''
        [ ! -f "$LOCK_DIR/pid" ] || read -r owner < "$LOCK_DIR/pid"
        if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
            rm -f "$LOCK_DIR/pid"
            rmdir "$LOCK_DIR" 2>/dev/null || true
        elif [ -z "$owner" ] && [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +15 2>/dev/null)" ]; then
            rmdir "$LOCK_DIR" 2>/dev/null || true
        fi
        tries=$((tries + 1))
        [ "$tries" -ge 3 ] && return 1
        sleep 2
    done
    echo "$$" > "$LOCK_DIR/pid"
    trap 'rm -f "$LOCK_DIR/pid"; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    return 0
}

fmt_time() {
    # $1 = epoch seconds -> local human time (GNU and BSD date)
    local e="$1"
    date -d "@$e" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
        || date -r "$e" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
        || echo "$e"
}

# ---------------------------------------------------------------------------
# Quiet hours
# ---------------------------------------------------------------------------
in_quiet_hours() {
    [ -n "$QUIET_HOURS" ] || return 1
    local re='^([0-9]{1,2}):([0-9]{2})-([0-9]{1,2}):([0-9]{2})$'
    local spec; spec="$(printf '%s' "$QUIET_HOURS" | tr -d '[:space:]')"
    [[ "$spec" =~ $re ]] || return 1
    local sh=$((10#${BASH_REMATCH[1]})) sm=$((10#${BASH_REMATCH[2]}))
    local eh=$((10#${BASH_REMATCH[3]})) em=$((10#${BASH_REMATCH[4]}))
    # Without this, a range like 00:00-99:00 would silence the whole day.
    [ "$sh" -le 23 ] && [ "$eh" -le 23 ] && [ "$sm" -le 59 ] && [ "$em" -le 59 ] || return 1
    local start=$((sh * 60 + sm))
    local end=$((eh * 60 + em))
    local now=$((10#$(date +%H) * 60 + 10#$(date +%M)))
    if [ "$start" -le "$end" ]; then
        [ "$now" -ge "$start" ] && [ "$now" -lt "$end" ]
    else
        [ "$now" -ge "$start" ] || [ "$now" -lt "$end" ]
    fi
}

# ---------------------------------------------------------------------------
# Providers
# ---------------------------------------------------------------------------
PING_MESSAGE=''
# Set by a ping that failed only because the subscription quota is used up:
# the epoch second after which a retry makes sense.
PING_RETRY_AT=0
QUOTA_RETRY_DEFAULT_MINUTES=60

# Raw CLI output is only ever matched here, never printed or logged.
quota_exhausted() {
    # Only the subscription-quota wording. Generic words such as "quota" or
    # "429" also appear in unrelated faults (disk quota, transient throttling)
    # and would turn a real, persistent failure into a silent deferral.
    printf '%s' "$1" | grep -qiE 'usage[_ -]?limit|hit your[^.]{0,30}limit|(weekly|5-hour|five-hour|session|opus|sonnet) limit|limit reached'
}

quota_retry_at() {
    # Codex says "... try again in 2 days 3 hours 5 minutes". Only digits are
    # taken from that text; anything unreadable falls back to one hour. The
    # result is clamped to [30 minutes, 7 days] so a parsing surprise can
    # neither hammer the provider nor park the schedule for weeks.
    local hint days hours mins total
    hint="$(printf '%s' "$1" | tr '\n' ' ' | grep -oiE 'try again in[^.]{0,80}' | head -1)"
    days="$(printf '%s' "$hint"  | grep -oiE '[0-9]+ *days?'            | head -1 | tr -cd '0-9')"
    hours="$(printf '%s' "$hint" | grep -oiE '[0-9]+ *(hours?|hrs?)'    | head -1 | tr -cd '0-9')"
    mins="$(printf '%s' "$hint"  | grep -oiE '[0-9]+ *(minutes?|mins?)' | head -1 | tr -cd '0-9')"
    days="$(to_int "$days")"   || days=0
    hours="$(to_int "$hours")" || hours=0
    mins="$(to_int "$mins")"   || mins=0
    total=$(( days * 1440 + hours * 60 + mins ))
    [ "$total" -gt 0 ] || total="$QUOTA_RETRY_DEFAULT_MINUTES"
    [ "$total" -ge 30 ] || total=30
    [ "$total" -le 10080 ] || total=10080
    printf '%s' "$(( $(date +%s) + total * 60 ))"
}


# resolve_cli <name> -> echoes an absolute path, or nothing.
# Schedulers (cron, launchd) run with a stripped-down PATH, so an explicit path
# from config.env wins; the installer fills it in.
resolve_cli() {
    local name="$1" configured="" var candidate
    var="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')_BIN"
    configured="${!var:-}"

    if [ -n "$configured" ] && [ -x "$configured" ]; then
        printf '%s' "$configured"; return 0
    fi
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"; return 0
    fi
    for candidate in "$HOME/.local/bin/$name" \
                     "$HOME/bin/$name" \
                     "$HOME/.npm-global/bin/$name" \
                     "/usr/local/bin/$name" \
                     "/opt/homebrew/bin/$name" \
                     "/usr/bin/$name"
    do
        [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
    done
    return 1
}

ping_claude() {
    PING_MESSAGE=''
    if [ -n "${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}" ] ||
       [ "${CLAUDE_CODE_USE_BEDROCK:-0}" = 1 ] || [ "${CLAUDE_CODE_USE_VERTEX:-0}" = 1 ] || [ "${CLAUDE_CODE_USE_FOUNDRY:-0}" = 1 ]; then
        PING_MESSAGE='API/provider credentials detected; use subscription login in a clean environment'
        return 1
    fi
    local exe
    if ! exe="$(resolve_cli claude)"; then
        PING_MESSAGE='claude CLI not found (set CLAUDE_BIN in config.env, or npm i -g @anthropic-ai/claude-code)'
        return 1
    fi

    local args=(
        -p "$CLAUDE_PROMPT"
        --model "$CLAUDE_MODEL"
        --system-prompt 'Reply with exactly: ok'
        --restricted --safe-mode --tools=
        --strict-mcp-config
        --no-session-persistence
        --permission-mode dontAsk
        --output-format json
    )

    if [ "$DO_DRYRUN" -eq 1 ]; then
        PING_MESSAGE="DRY RUN: claude ${args[*]}"
        return 0
    fi

    local out rc
    PING_RETRY_AT=0
    out="$(cd "$WORK_DIR" && run_bounded_cli "$exe" "${args[@]}" 2>&1)"; rc=$?

    if [ "$rc" -ne 124 ] && quota_exhausted "$out" &&
       { [ "$rc" -ne 0 ] || printf '%s' "$out" | grep -q '"is_error"[[:space:]]*:[[:space:]]*true'; }; then
        PING_RETRY_AT="$(quota_retry_at "$out")"
        PING_MESSAGE='claude usage limit reached (CLI output withheld)'
        return 1
    fi

    # Matching on text alone is not enough: an unrecognised failure would be
    # recorded as a successful ping and stall the schedule for five hours.
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 124 ]; then
            PING_MESSAGE='claude timed out after 120 seconds (CLI output withheld)'
        else
            # A fixed category only, never the CLI's own text.
            local klass=provider_error
            if   printf '%s' "$out" | grep -qiE '(^|[^0-9])401([^0-9]|$)|unauthori[sz]ed|not logged in|authentication|expired'; then klass=authentication
            elif printf '%s' "$out" | grep -qiE 'overloaded|(^|[^0-9])(500|502|503|529)([^0-9]|$)|internal server'; then klass=provider_outage
            elif printf '%s' "$out" | grep -qiE 'network|connection|econn|dns|certificate|tls|timed out'; then klass=network
            elif printf '%s' "$out" | grep -qiE 'limit'; then klass=unrecognised_limit
            fi
            PING_MESSAGE="claude exited $rc (class=$klass; CLI output withheld)"
        fi
        return 1
    fi

    if printf '%s' "$out" | grep -qi 'not logged in'; then
        PING_MESSAGE='not logged in - run: claude auth login'
        return 1
    fi
    if printf '%s' "$out" | grep -q '"is_error"[[:space:]]*:[[:space:]]*true'; then
        PING_MESSAGE='claude returned an error (CLI output withheld)'
        return 1
    fi
    if ! printf '%s' "$out" | grep -q '"type"[[:space:]]*:[[:space:]]*"result"'; then
        PING_MESSAGE='unreadable claude output (CLI output withheld)'
        return 1
    fi
    if ! printf '%s' "$out" | grep -q '"subtype"[[:space:]]*:[[:space:]]*"success"' ||
       ! printf '%s' "$out" | grep -q '"is_error"[[:space:]]*:[[:space:]]*false'; then
        PING_MESSAGE='claude did not return a successful result (CLI output withheld)'
        return 1
    fi

    # A local/cached acknowledgement without model usage is not a verified ping.
    # Only emit numeric usage fields; never expose raw output or credentials.
    local output_tokens
    output_tokens="$(printf '%s' "$out" | grep -oE '"output_tokens"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | tr -cd '0-9')"
    if [ -z "$output_tokens" ] || [ "$output_tokens" = 0 ]; then
        PING_MESSAGE='claude returned no output tokens; quota-window activation is unverified'
        return 1
    fi
    PING_MESSAGE="claude ok (model=$CLAUDE_MODEL output_tokens=$output_tokens; provider reset time unverified)"
    return 0
}

ping_codex() {
    PING_MESSAGE=''
    local exe failure_class failure_detail
    if ! exe="$(resolve_cli codex)"; then
        PING_MESSAGE='codex CLI not found (set CODEX_BIN in config.env, or npm i -g @openai/codex)'
        return 1
    fi

    local args=(exec --skip-git-repo-check --ephemeral --ignore-user-config --ignore-rules --json -s read-only -c project_doc_max_bytes=0 -c 'forced_login_method="chatgpt"' -C "$WORK_DIR")
    [ -n "$CODEX_MODEL" ] && args+=(-m "$CODEX_MODEL")
    [ -n "$CODEX_REASONING_EFFORT" ] && args+=(-c "model_reasoning_effort=\"$CODEX_REASONING_EFFORT\"")
    args+=(-- "$CODEX_PROMPT")

    if [ "$DO_DRYRUN" -eq 1 ]; then
        PING_MESSAGE="DRY RUN: codex ${args[*]}"
        return 0
    fi

    local out rc event_types
    PING_RETRY_AT=0
    out="$(run_bounded_cli "$exe" "${args[@]}" 2>&1)"; rc=$?

    # Event names are a small, non-secret part of JSONL output. They make a
    # failed cloud run diagnosable without publishing prompts, responses,
    # account data or raw CLI errors.
    event_types="$(printf '%s' "$out" |
        grep -oE '"type"[[:space:]]*:[[:space:]]*"[A-Za-z0-9._-]+"' |
        sed -E 's/.*"([A-Za-z0-9._-]+)"/\1/' | sort -u | head -10 |
        tr '\n' ',' | sed 's/,$//' || true)"

    if [ "$rc" -ne 124 ] && quota_exhausted "$out" &&
       ! printf '%s' "$out" | grep -qE '"type"[[:space:]]*:[[:space:]]*"turn.completed"'; then
        PING_RETRY_AT="$(quota_retry_at "$out")"
        PING_MESSAGE="codex usage limit reached (event types=${event_types:-none}; CLI output withheld)"
        return 1
    fi

    failure_class=provider_error
    failure_detail=none
    if printf '%s' "$out" | grep -qiE 'usage[_ -]?limit|quota'; then
        failure_class=usage_limit
    elif printf '%s' "$out" | grep -qiE '(^|[^0-9])401([^0-9]|$)|unauthori[sz]ed|not logged in|authentication'; then
        failure_class=authentication
    elif printf '%s' "$out" | grep -qiE '(^|[^0-9])429([^0-9]|$)|rate[_ -]?limit'; then
        failure_class=rate_limit
    elif printf '%s' "$out" | grep -qiE 'model[_ -]?(not[_ -]?found|unsupported)|unknown model'; then
        failure_class=model
    elif printf '%s' "$out" | grep -qiE 'network|connection|connect error|dns|certificate|tls'; then
        failure_class=network
    elif printf '%s' "$out" | grep -qiE 'sandbox|landlock|seccomp|permission denied'; then
        failure_class=sandbox
    fi

    # Publish only a fixed category, never the provider's raw error text.
    if printf '%s' "$out" | grep -qiE 'name resolution|resolve host|dns'; then
        failure_detail=dns
    elif printf '%s' "$out" | grep -qiE 'certificate|tls|ssl'; then
        failure_detail=tls
    elif printf '%s' "$out" | grep -qiE 'proxy'; then
        failure_detail=proxy
    elif printf '%s' "$out" | grep -qiE 'websocket|web socket'; then
        failure_detail=websocket
    elif printf '%s' "$out" | grep -qiE 'http[/ -]?2|h2 protocol'; then
        failure_detail=http2
    elif printf '%s' "$out" | grep -qiE 'stream disconnected|connection closed|connection reset'; then
        failure_detail=stream_disconnect
    elif printf '%s' "$out" | grep -qiE 'timed out|timeout'; then
        failure_detail=connect_timeout
    elif printf '%s' "$out" | grep -qiE 'error sending request|connect error|connection'; then
        failure_detail=request
    fi

    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 124 ]; then
            PING_MESSAGE="codex timed out after 120 seconds (class=$failure_class detail=$failure_detail event types=${event_types:-none}; CLI output withheld)"
        else
            PING_MESSAGE="codex exited $rc (class=$failure_class detail=$failure_detail event types=${event_types:-none}; CLI output withheld)"
        fi
        return 1
    fi

    if printf '%s' "$out" | grep -qi 'not logged in'; then
        PING_MESSAGE='not logged in - run: codex login'
        return 1
    fi
    if printf '%s' "$out" | grep -qi '^ERROR:'; then
        PING_MESSAGE='codex reported an error (CLI output withheld)'
        return 1
    fi

    if printf '%s' "$out" | grep -qE '"type"[[:space:]]*:[[:space:]]*"(turn.failed|error)"' ||
       ! printf '%s' "$out" | grep -qE '"type"[[:space:]]*:[[:space:]]*"turn.completed"'; then
        PING_MESSAGE="codex returned no successful completed turn (class=$failure_class detail=$failure_detail event types=${event_types:-none}; CLI output withheld)"
        return 1
    fi
    PING_MESSAGE='codex ok'
    return 0
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
show_status() {
    local now; now="$(date +%s)"
    echo
    echo "  No 5-Hour Limit - status"
    echo "  ---------------------------------------------------------"
    echo "  config       : $CONFIG_PATH"
    echo "  interval     : $INTERVAL_MINUTES minutes"
    if [ -n "$QUIET_HOURS" ]; then
        if in_quiet_hours; then
            echo "  quiet hours  : $QUIET_HOURS (ACTIVE right now)"
        else
            echo "  quiet hours  : $QUIET_HOURS (inactive)"
        fi
    else
        echo "  quiet hours  : disabled (24/7)"
    fi
    echo

    local name enabled last retry ends nextp remain
    for name in claude codex; do
        if [ "$name" = claude ]; then enabled="$CLAUDE_ENABLED"; last="$CLAUDE_LAST"; retry="$CLAUDE_RETRY"
        else enabled="$CODEX_ENABLED"; last="$CODEX_LAST"; retry="$CODEX_RETRY"; fi

        if ! is_true "$enabled"; then
            printf '  %-6s       : disabled\n' "$name"
            continue
        fi
        if [ "$retry" -gt "$now" ]; then
            printf '  %-6s       : usage limit reached - next attempt %s\n' "$name" "$(fmt_time "$retry")"
        fi
        if [ "$last" -eq 0 ]; then
            printf '  %-6s       : enabled - no successful ping yet\n' "$name"
            continue
        fi

        ends=$((last + 300 * 60))
        nextp=$((last + INTERVAL_MINUTES * 60))
        remain=$((ends - now))

        printf '  %-6s       : enabled\n' "$name"
        printf '     last ping   %s\n' "$(fmt_time "$last")"
        if [ "$remain" -gt 0 ]; then
            printf '     estimated window end %s  (%dh %dm left; not provider-reported)\n' "$(fmt_time "$ends")" "$((remain / 3600))" "$(((remain % 3600) / 60))"
        else
            printf '     estimated window end %s  (expired; not provider-reported)\n' "$(fmt_time "$ends")"
        fi
        printf '     next ping   %s\n' "$(fmt_time "$nextp")"
    done

    echo
    # When driven from cloud.env / the cloud state file, the local cron entry is
    # not the thing running this - saying "NOT INSTALLED" there is just wrong.
    case "$CONFIG_PATH$STATE_FILE" in
        *cloud*)
            echo "  scheduler    : GitHub Actions (.github/workflows/keepalive.yml)"
            echo "     check runs  gh run list --workflow keepalive.yml"
            ;;
        *)
            if [ "$(uname -s)" = "Darwin" ] &&
               launchctl list 2>/dev/null | grep -q 'com.no5hourlimit.keepalive'; then
                echo "  scheduler    : LaunchAgent loaded (com.no5hourlimit.keepalive)"
            elif crontab -l 2>/dev/null | grep -q 'keepalive.sh'; then
                echo "  scheduler    : cron entry found"
                crontab -l 2>/dev/null | grep 'keepalive.sh' | sed 's/^/     /'
            else
                echo "  scheduler    : NOT INSTALLED - run install/install-unix.sh"
            fi
            ;;
    esac
    echo "  log file     : $LOG_FILE"
    echo
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [ "$DO_STATUS" -eq 1 ]; then
    show_status
    exit 0
fi

# --enabled: name the providers this config turns on. The workflow uses this
# instead of grepping the config itself, so there is one interpretation of
# "enabled" rather than two that can disagree about quoting or a missing key.
if [ "$DO_ENABLED" -eq 1 ]; then
    ENABLED_LIST=""
    is_true "$CLAUDE_ENABLED" && ENABLED_LIST="$ENABLED_LIST claude"
    is_true "$CODEX_ENABLED"  && ENABLED_LIST="$ENABLED_LIST codex"
    printf '%s\n' "${ENABLED_LIST# }"
    exit 0
fi

# --due: report which providers need a ping and say so through the exit code,
# without contacting anything. Lets a caller skip expensive setup on a no-op
# run (exit 0 = at least one is due, exit 3 = nothing to do).
if [ "$DO_DUE" -eq 1 ]; then
    DUE_LIST=""
    NOW="$(date +%s)"
    for provider in claude codex; do
        if [ "$provider" = claude ]; then enabled="$CLAUDE_ENABLED"; last="$CLAUDE_LAST"; retry="$CLAUDE_RETRY"
        else enabled="$CODEX_ENABLED"; last="$CODEX_LAST"; retry="$CODEX_RETRY"; fi
        is_true "$enabled" || continue
        if [ "$last" -gt 0 ] && [ $(( (NOW - last) / 60 )) -lt "$INTERVAL_MINUTES" ]; then
            continue
        fi
        [ "$NOW" -ge "$retry" ] || continue
        DUE_LIST="$DUE_LIST $provider"
    done
    if in_quiet_hours; then
        printf 'quiet hours active (%s) - nothing due
' "$QUIET_HOURS"
        exit 3
    fi
    if [ -n "$DUE_LIST" ]; then
        printf '%s
' "${DUE_LIST# }"
        exit 0
    fi
    echo 'nothing due'
    exit 3
fi

prune_logs

if in_quiet_hours && [ "$DO_FORCE" -eq 0 ]; then
    log info "quiet hours active ($QUIET_HOURS) - skipping"
    exit 0
fi

acquire_lock || {
    log warn "another run is already working - skipping this one"
    exit 0
}

# Reload after taking the lock: another run may have finished while we waited.
load_state

ANY_FAIL=0

for provider in claude codex; do
    if [ "$provider" = claude ]; then enabled="$CLAUDE_ENABLED"; last="$CLAUDE_LAST"; retry="$CLAUDE_RETRY"
    else enabled="$CODEX_ENABLED"; last="$CODEX_LAST"; retry="$CODEX_RETRY"; fi

    is_true "$enabled" || continue

    # Read the clock per provider: a slow first ping must not make the second
    # one look older than it is.
    NOW="$(date +%s)"

    if [ "$DO_FORCE" -eq 0 ] && [ "$last" -gt 0 ]; then
        [ $(( (NOW - last) / 60 )) -lt "$INTERVAL_MINUTES" ] && continue
    fi
    [ "$DO_FORCE" -eq 1 ] || [ "$NOW" -ge "$retry" ] || continue

    if [ "$provider" = claude ]; then ping_claude; rc=$?; else ping_codex; rc=$?; fi

    if [ "$rc" -eq 0 ]; then
        log info "$PING_MESSAGE"
        if [ "$DO_DRYRUN" -eq 0 ]; then
            # Start the interval at the successful response. A slow CLI call
            # must not shorten the next five-hour window.
            success_now="$(date +%s)"
            if [ "$provider" = claude ]; then CLAUDE_LAST="$success_now"; CLAUDE_RETRY=0
            else CODEX_LAST="$success_now"; CODEX_RETRY=0; fi
            # Save straight away. Batching the write to the end means a hang or
            # a job timeout on the second provider throws away the first one's
            # success, and the next run pings it again for nothing.
            save_state || ANY_FAIL=1
        fi
    elif [ "$PING_RETRY_AT" -gt 0 ]; then
        # Quota exhaustion is the provider working as designed, not a broken
        # job. Record when to try again and keep the exit status clean.
        log warn "$provider: $PING_MESSAGE - next attempt $(fmt_time "$PING_RETRY_AT")"
        if [ "$DO_DRYRUN" -eq 0 ]; then
            if [ "$provider" = claude ]; then CLAUDE_RETRY="$PING_RETRY_AT"; else CODEX_RETRY="$PING_RETRY_AT"; fi
            save_state || ANY_FAIL=1
        fi
    else
        ANY_FAIL=1
        log error "$provider: $PING_MESSAGE"
    fi
done

exit "$ANY_FAIL"
