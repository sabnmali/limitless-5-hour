#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# No 5-Hour Limit - one command that finishes the cloud setup (macOS / Linux).
#
# It will:
#   1. check that gh and claude are available and signed in
#   2. run `claude setup-token`, which opens your browser so you can approve
#   3. ask you to paste the token it printed
#   4. store it as the CLAUDE_CODE_OAUTH_TOKEN repository secret
#   5. enable the workflow, trigger a due check and wait for the result
#
# The token is never written to a file and never printed back.
#
#   ./install/setup-cloud.sh                    detect the repo from git
#   ./install/setup-cloud.sh --repo owner/name  say it explicitly
#   ./install/setup-cloud.sh --codex            upload auth.json from a dedicated CODEX_HOME
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

REPO=""
WITH_CODEX=0

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)   shift; REPO="${1:-}" ;;
        --codex)  WITH_CODEX=1 ;;
        -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  OK  %s\n' "$*"; }
warn() { printf '  !   %s\n' "$*"; }
die()  { printf '  X   %s\n' "$*" >&2; exit 1; }
head_() { printf '\n  %s\n' "$*"; }

echo
echo "  No 5-Hour Limit - cloud setup"
echo "  ============================================================"

# --- 1. tools --------------------------------------------------------------
head_ "Step 1 of 5 - checking the tools"

command -v gh >/dev/null 2>&1 || \
    die "The GitHub CLI (gh) is not installed. See https://cli.github.com then run this again."

if ! gh auth status >/dev/null 2>&1; then
    warn "You are not signed in to GitHub. Starting the sign-in now..."
    gh auth login
    gh auth status >/dev/null 2>&1 || die "Still not signed in to GitHub - stopping."
fi
ok "GitHub CLI ready"

if ! command -v claude >/dev/null 2>&1; then
    # Having the Claude desktop app does not put `claude` on your PATH - the app
    # carries its own private copy. The command-line tool is a separate install.
    warn "The claude command-line tool is not installed on this computer yet."
    say  "(The Claude desktop app has its own private copy that other programs cannot use.)"
    echo
    command -v npm >/dev/null 2>&1 || \
        die "Installing it needs Node.js. Get it from https://nodejs.org then run this script again."

    printf '  Install it now? (press Enter for yes, or type n): '
    IFS= read -r answer
    case "$answer" in
        [nNhH]*) die "Nothing installed. Run this again when you are ready." ;;
    esac

    say "Installing - this takes a minute..."
    npm install -g @anthropic-ai/claude-code \
        || die "The install failed. Try running this by hand:  npm install -g @anthropic-ai/claude-code"

    hash -r 2>/dev/null || true
    command -v claude >/dev/null 2>&1 || \
        die "Installed, but the claude command still is not visible. Open a new terminal and run this script again."
    ok "claude installed: $(command -v claude)"
else
    ok "claude command found: $(command -v claude)"
fi

# --- 2. which repository ---------------------------------------------------
if [ -z "$REPO" ]; then
    remote="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
    # Keep dots in the name and strip only a trailing .git. The old
    # ([^/.]+) turned owner/keep.alive.git into owner/keep, which would have
    # uploaded the token to a different repository or failed outright.
    if [[ "$remote" =~ github\.com[:/]+([^/]+)/([^/]+)$ ]]; then
        REPO="${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
    fi
fi
[ -n "$REPO" ] || die "Could not work out which GitHub repository to use. Re-run with:  --repo owner/name"
ok "repository: $REPO"

visibility="$(gh repo view "$REPO" --json visibility --jq '.visibility' 2>/dev/null || true)"
[ "$visibility" = PRIVATE ] || \
    die "Cloud setup requires a PRIVATE deployment repository created from the public template."
ok "private deployment repository confirmed"

# --- 3. the token ----------------------------------------------------------
head_ "Step 2 of 5 - creating your login token"
say "A browser window will open. Sign in and approve, then come back here."
echo

claude setup-token || die "Token setup failed."

echo
say "Copy the long token printed above,"
printf '  paste it here and press Enter (it will not be shown): '
# Echo off: the CLI already put the token on screen once. Repeating it in the
# scrollback of a terminal that may be recorded is a needless second exposure.
[ -t 0 ] || die "Run this interactively in your own terminal."
terminal_state="$(stty -g)" || die "Cannot read terminal state."
trap 'stty "$terminal_state" 2>/dev/null' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
stty -echo || die "Cannot hide token input."
IFS= read -r TOKEN || die "No token received."
stty "$terminal_state"
trap - EXIT INT TERM
echo
TOKEN="$(printf '%s' "$TOKEN" | tr -d '[:space:]')"

[ "${#TOKEN}" -ge 20 ] || die "That does not look like a token. Run the script again and paste the whole line."
ok "token received"

# --- 4. store it -----------------------------------------------------------
head_ "Step 3 of 5 - storing it on GitHub"

printf '%s' "$TOKEN" | gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo "$REPO" \
    || die "Could not store the secret. Check that you have access to the repository."
TOKEN=""
ok "CLAUDE_CODE_OAUTH_TOKEN stored (it is not saved anywhere on this computer)"
gh variable set L5H_CLAUDE_ENABLED --body true --repo "$REPO" \
    || die "Claude credentials were stored, but the provider could not be enabled."
ok "cloud Claude enabled for this repository"

if [ "$WITH_CODEX" -eq 1 ]; then
    [ -n "${CODEX_HOME:-}" ] || die 'Set CODEX_HOME to a separate cloud login directory first. See NETLIFY.md.'
    [ -d "$CODEX_HOME" ] || die 'CODEX_HOME does not exist. Create it and run codex login there first. See NETLIFY.md.'
    [ "$(cd "$CODEX_HOME" && pwd -P)" != "$(cd "$HOME/.codex" && pwd -P)" ] || die 'Do not upload the desktop login. Use a dedicated CODEX_HOME.'
    gh secret list --repo "$REPO" --json name --jq '.[].name' | grep -qx CODEX_SECRET_UPDATE_TOKEN || die 'Create repository-scoped CODEX_SECRET_UPDATE_TOKEN first. See NETLIFY.md.'
    if [ -f "$CODEX_HOME/auth.json" ]; then
        command -v node >/dev/null 2>&1 || die 'Node.js is required to validate Codex auth.json.'
        node -e 'const fs=require("fs");const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));if(j.auth_mode!=="chatgpt"||!j.tokens||!j.tokens.refresh_token)process.exit(1)' "$CODEX_HOME/auth.json" \
            || die 'Codex auth.json is not a ChatGPT-managed login with a refresh token. See NETLIFY.md.'
        gh secret set CODEX_AUTH_JSON --repo "$REPO" < "$CODEX_HOME/auth.json" \
            || die "Could not store CODEX_AUTH_JSON. Codex was not enabled."
        ok "CODEX_AUTH_JSON stored"
        gh variable set L5H_CODEX_ENABLED --body true --repo "$REPO" \
            || die "Credentials were stored, but Codex could not be enabled. Check repository Actions-variable access."
        ok "cloud Codex enabled for this repository"
        # The cloud copy now owns this login. Its first refresh retires the
        # local token, and using the local copy first would retire the cloud
        # one, so a leftover file is only a credential lying on disk.
        printf '  Delete the local copy %s now? [Y/n] ' "$CODEX_HOME/auth.json"
        answer=''
        IFS= read -r answer || answer=''
        case "$answer" in
            n|N|no|NO) warn "kept $CODEX_HOME/auth.json - do not run codex with this CODEX_HOME, or the cloud login stops working" ;;
            *) rm -f -- "$CODEX_HOME/auth.json" && ok "local copy deleted" ;;
        esac
    else
        die "No auth.json found in CODEX_HOME. Run 'codex login' with that dedicated home first."
    fi
fi

# --- 5. first window -------------------------------------------------------
head_ "Step 4 of 5 - starting the first due check"

gh workflow enable keepalive.yml --repo "$REPO" \
    || die "Could not enable keepalive.yml in the private repository."

# Remember what already exists, so a run left over from cron is never mistaken
# for the one this script is about to start.
BEFORE="$(gh run list --workflow keepalive.yml --event workflow_dispatch --limit 20 --json databaseId \
          --jq '[.[].databaseId] | join(",")' --repo "$REPO" 2>/dev/null || true)"

gh workflow run keepalive.yml --repo "$REPO" \
    || die "Could not start the workflow. Is Actions enabled on the repository?"
ok "workflow started"

# --- 6. wait and report ----------------------------------------------------
head_ "Step 5 of 5 - waiting for the result"

deadline=$(( $(date +%s) + 180 ))
run_id=""
while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 5

    # Pick the newest run that was not there before the dispatch, then follow
    # that fixed id. Watching "the latest run" could report success from a run
    # that finished before this script even started.
    if [ -z "$run_id" ]; then
        for candidate in $(gh run list --workflow keepalive.yml --event workflow_dispatch --limit 20 \
                           --json databaseId --jq '.[].databaseId' --repo "$REPO" 2>/dev/null); do
            case ",$BEFORE," in
                *",$candidate,"*) ;;
                *) run_id="$candidate"; break ;;
            esac
        done
        [ -n "$run_id" ] || { printf '.'; continue; }
    fi

    json="$(gh run view "$run_id" --json status,conclusion --repo "$REPO" 2>/dev/null || true)"
    [ -n "$json" ] || continue

    status="$(printf '%s' "$json"     | tr -d ' \n' | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')"
    conclusion="$(printf '%s' "$json" | tr -d ' \n' | sed -n 's/.*"conclusion":"\([^"]*\)".*/\1/p')"

    if [ "$status" = "completed" ]; then
        echo
        if [ "$conclusion" = "success" ]; then
            ok "Due check completed. In a fresh deployment, inspect the provider job for actual success; reset times are estimates."
            echo
            say "Details: https://github.com/$REPO/actions/runs/$run_id"
            echo
            say "Nothing else to do. You can close this window."
            echo
            exit 0
        fi
        warn "The run finished with: $conclusion"
        say  "Look at what went wrong: https://github.com/$REPO/actions/runs/$run_id"
        say  "The most common cause is a token pasted incomplete - just run this script again."
        exit 1
    fi
    printf '.'
done

echo
warn "Verification timed out after 3 minutes; outcome unknown. Check:"
say  "https://github.com/$REPO/actions"

exit 1
