# Instructions for an AI coding agent

<!-- CLAUDE.md and AGENTS.md are kept identical on purpose: different
     tools look for different filenames. Edit one, mirror the other. -->

This file is for an assistant (Codex, Claude Code, or similar) that has been
pointed at this repository and asked to set it up for its user. Read
[README.md](README.md) for the full picture; this is the short operational
version.

## What this repository is

A keepalive. It sends a one-word prompt to the Claude CLI (and optionally the
Codex CLI) once 301 minutes have elapsed since the last successful ping, which
may start an idle usage window. It does not read provider reset times, raise
limits, or guarantee quota availability. All pings consume usage. Normal
ChatGPT chat allowances are separate from Codex; do not claim this activates
every application or model counter. See the coverage table in README.md.

## Decide which route the user wants

| Route | Runs on | Works while the user's machine is off |
|---|---|---|
| **Cloud** (recommended) | GitHub Actions | yes |
| **Local** | Task Scheduler / launchd / cron | no |

Choose one scheduler per provider/account across all devices. Claude in the
cloud and Codex locally is valid; do not enable the same provider in both.
Prefer local Codex: copied refresh credentials can become stale or conflict
with the desktop session. Cloud Codex requires ongoing credential maintenance.
The public repository is source code only. Every cloud deployment that stores
subscription credentials must be a separate PRIVATE repository created from the
public template; the setup scripts deliberately refuse public repositories.
For independent Netlify dispatch and dedicated cloud Codex credential
persistence, follow NETLIFY.md. Use separate repository-scoped dispatch and
secret-update tokens; never copy an account-wide GitHub CLI token to Netlify.

## Cloud route

```bash
# Windows
powershell -ExecutionPolicy Bypass -File install\setup-cloud-windows.ps1
# macOS / Linux
./install/setup-cloud.sh
```

That script handles everything except the parts only a human can do. **You
must not run it for the user in a non-interactive shell** - it opens a browser
for sign-in and prompts for a pasted token. Tell the user to run it themselves
in their own terminal, and say why.

Before pointing them at it, you can usefully:

1. Confirm `gh` and `claude` are installed, and install what is missing
   (`npm install -g @anthropic-ai/claude-code`, https://cli.github.com).
2. Create a private deployment from the public template, if they have not:
   `gh repo create my-limitless-5-hour --private --template sabnmali/limitless-5-hour --clone`
3. Check `cloud.env` matches what they want. The source defaults both providers
   off; setup sets `L5H_CLAUDE_ENABLED`, and `--codex` / `-Codex` also sets
   `L5H_CODEX_ENABLED` after its private-repo secrets exist.
4. After they have run the setup script, verify:
   `gh run list --workflow keepalive.yml -L 3`

**Never handle the token yourself.** `claude setup-token` prints a credential
for the user's subscription. Do not run it, capture it, echo it, write it to a
file, or paste it into anything. The setup script keeps it in memory and pipes
it straight to `gh secret set`.

## Local route

Windows laptop safety: local automation requires explicit `-EnableLocal`.
Never reactivate a disabled task while troubleshooting laptop disruption unless
the user asks. Use install/disable-local-windows.ps1 to stop this checkout's task.
Do not enable WakeToRun or battery execution. Hidden PowerShell does not prove
there can be no console flash; do not attribute display changes without evidence.

```bash
# Windows
powershell -ExecutionPolicy Bypass -File install\install-windows.ps1 -EnableLocal
# macOS / Linux
./install/install-unix.sh
```

On Windows the installer registers the scheduler, pins the absolute CLI paths
into `config.env`, installs the Claude Code skill, and then runs the job once
to prove the scheduler can actually reach the CLI. The Unix installer does the
first three; it does not run that verification. On Windows, if it reports that
the scheduled task cannot see `claude`, run
`install\setup-cli-windows.ps1` - the npm global folder is not always visible
to the Task Scheduler service, and that script switches to the native build.

The user still has to run `claude auth login` once themselves.

## Configuration

Two plain `KEY=VALUE` files, same keys in both:

- `config.env` - local scheduler only. Git-ignored, created from
  `config.example.env` by the installer.
- `cloud.env` - safe public-template defaults with both providers off. The
  private deployment variables `L5H_CLAUDE_ENABLED` and `L5H_CODEX_ENABLED`
  override only the matching switches.

The status view's "window ends" is an estimate: it is the last ping plus five
hours. If the user opened the window themselves before the ping, the real
boundary is earlier.

Keys: `INTERVAL_MINUTES` (do not go below 300), `CLAUDE_ENABLED`,
`CLAUDE_MODEL`, `CLAUDE_PROMPT`, `CLAUDE_BIN`, `CODEX_ENABLED`, `CODEX_MODEL`,
`CODEX_PROMPT`, `CODEX_BIN`, `CODEX_REASONING_EFFORT`, `LOG_RETENTION_DAYS`,
`QUIET_HOURS`.

## Checking on it

```bash
# local state
./bin/keepalive.sh --status
powershell -ExecutionPolicy Bypass -File bin\keepalive.ps1 -Status

# cloud state
L5H_STATE_FILE=state/cloud-state.env ./bin/keepalive.sh --config cloud.env --status
gh run list --workflow keepalive.yml -L 5
```

`--due` reports what is owed and exits 3 when nothing is; `--enabled` lists
the providers a config turns on; `--force` pings immediately.

Be accurate about `--force`: it sends a message now, ignoring the interval and
quiet hours. It does **not** close or reset a window that is already open - a
message inside a live window changes nothing except spending a little quota.
It only opens a new window if the previous one has already expired.

## Security expectations

[SECURITY.md](SECURITY.md) is the reference. The parts you must not undo:

- Keep the workflow's triggers to `schedule` and `workflow_dispatch`. Adding
  `pull_request` would let a fork run it.
- Keep the default permission read-only. Only the fresh `save` job may receive
  `contents: write`; provider jobs must not receive it.
- Keep Claude and Codex in separate jobs. Codex runs in a disposable container
  so provider code cannot observe the later secret-update token.
- Do not add a force/bypass input to the externally dispatchable workflow.
- Keep third-party actions pinned to commit SHAs.
- Keep the config-key allowlists in both keepalive scripts. They are what stops
  a config file from reassigning `PATH` or the state file location.
- Keep the log redactor and never log raw CLI output.
- Keep run locks, bounded CLI invocation, success validation, and atomic state writes.
- The separate offline test workflow has read-only permissions and no AI secrets.
- Never lower `INTERVAL_MINUTES` below its 300-minute floor.

## Things that will bite you

- **The Claude desktop app does not give the user the `claude` command.** The
  app ships its own private copy that other programs cannot call. The CLI is a
  separate `npm install -g @anthropic-ai/claude-code`. Check with
  `Get-Command claude` / `command -v claude` in the user's own terminal - a
  tool sandbox can see a copy that the machine itself does not have.
- **Schedulers do not inherit your shell's PATH.** That is what `CLAUDE_BIN` /
  `CODEX_BIN` are for; the installers fill them in.
- **The CLI's login is separate from the Claude desktop app.** `claude auth
  status` reporting `loggedIn: false` while the desktop app works is normal.
- **Codex refresh tokens rotate.** A `CODEX_AUTH_JSON` secret can go stale and
  interfere with a shared desktop login. Prefer local Codex or a dedicated
  maintained cloud login. OpenAI restricts auth.json CI use to trusted private
  automation. Never commit auth.json or add it to an artifact/cache.
- **Do not set `INTERVAL_MINUTES` below 300.** Pinging inside a live window
  consumes quota without opening a new window.
- **`.sh` files must keep LF endings.** `.gitattributes` enforces this; do not
  override it.
