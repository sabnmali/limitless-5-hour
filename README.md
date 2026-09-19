# No 5-Hour Limit

A scheduled, minimal prompt for the official Claude Code and Codex CLIs.
[Türkçe](README.tr.md) · [Security](SECURITY.md)

## What it actually does

Checks periodically and sends `ok` when at least **301 minutes** have passed
since that provider's last successful ping. Each provider has independent state.
A ping may start an idle usage window; it cannot reset a window already in
progress, increase your allowance, or guarantee that quota will be available
when you return. All pings consume usage, including weekly allowances.

The name is not a promise of unlimited use. The script tracks **its own ping
timestamps**, not the provider's actual window boundaries. A successful CLI
response proves a message was processed, not that a new window opened.

## Which apps and models does it cover?

| Surface | Coverage |
|---|---|
| Claude / Claude Code / Cowork | Claude Code usage contributes to the shared allowance on applicable subscription plans. Additional model, feature, weekly and monthly limits still apply. |
| Codex | Sends a message through the official Codex CLI using ChatGPT login. |
| Normal ChatGPT conversations | **Not supported.** Chat usage rules are separate from Work/Codex. A Codex ping does not start all ChatGPT model counters. |
| Other AI tools or models | No generic support. An official integration and that provider's actual metering rules must be checked first. |

Provider references (reviewed September 2026):
[OpenAI: Chat versus Work/Codex allowances](https://help.openai.com/en/articles/20001354),
[Claude Code on Pro/Max](https://support.claude.com/en/articles/11145838-using-claude-code-with-your-pro-or-max-plan),
[Claude usage limits](https://support.claude.com/en/articles/9797557-usage-limit-best-practices).
Shared usage does not prove that one ping initializes every model-specific counter.

## Choose where it runs

Choose **one scheduler per provider/account**, including across devices.
Claude in the cloud and Codex locally is fine; running the same provider on
both independent schedules wastes quota.

- **Local:** Windows Task Scheduler, macOS launchd, Linux cron. Uses your existing
  CLI login and persistent credential storage. The computer must be awake and
  online. Windows is opt-in, requires you to be logged in and on AC power,
  and never wakes the computer. Some CLI console processes may still flash.
- **Cloud:** GitHub Actions. Works while your computer is off. Polls every 30
  minutes; GitHub can delay or drop scheduled runs, so timing is not guaranteed.
  Requires a subscription credential stored in your repository's Actions secrets.

**Cloud credentials belong in a private deployment repository.** This public
repository is source code only. [OpenAI's CI/CD auth guide](https://learn.chatgpt.com/docs/auth/ci-cd-auth)
limits ChatGPT-managed `auth.json` use to trusted private automation and says
not to use it in a public/open-source repository. Create a private repository from this template;
never add subscription credentials to a public fork.

**Prefer local Codex.** Its refresh credentials rotate. Copying the same login
into an ephemeral cloud runner can make the repository secret stale and conflict
with your desktop login. Cloud Codex is an optional setup requiring credential
maintenance, not an unattended permanent login. With a dedicated login and a
repository-scoped secret-update token, the workflow persists refreshed Codex
credentials. [Netlify setup and credential requirements](NETLIFY.md) also covers
an independent thirty-minute dispatcher when GitHub cron is delayed.

## Local installation

Install the official CLIs separately and log in with your subscription:

```sh
claude auth login
npm install -g @openai/codex
codex login  # optional; use ChatGPT sign-in, not an API key
```

Tested cloud CLI versions: Claude Code **2.1.276**, Codex **0.155.0**. Older versions
may lack the isolation flags used here. No runtime Python dependency is needed.

```sh
git clone https://github.com/sabnmali/limitless-5-hour.git
cd limitless-5-hour
```

Copy `config.example.env` to `config.env` and choose enabled providers before
installing, especially if Claude already runs in the cloud. For Codex only:

```ini
CLAUDE_ENABLED=false
CODEX_ENABLED=true
```

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install\install-windows.ps1 -EnableLocal
```

macOS / Linux:

```sh
./install/install-unix.sh
```

Installers register the scheduler, record CLI paths, and install the bundled
Claude skill. Windows also starts the task and checks its completion. A no-op
run is not proof of CLI connectivity. On macOS/Linux, run the script once to
check a due ping. If the CLI cannot be found, set its absolute `*_BIN` path.
`install/setup-cli-windows.ps1` can help install/login to the native Claude CLI.

## Cloud installation

Create a **private** deployment repository from this public template. Do not use
a public fork. For example:

```sh
gh repo create my-limitless-5-hour --private --template sabnmali/limitless-5-hour --clone
cd my-limitless-5-hour
```

Run the setup script **in your own interactive terminal**; Claude sign-in and
token entry require a person. An assistant can inspect and prepare the repository
but must never capture the printed Claude token.

```powershell
powershell -ExecutionPolicy Bypass -File install\setup-cloud-windows.ps1
```

```sh
./install/setup-cloud.sh
```

The source template enables no cloud provider. Setup stores the Claude secret,
sets `L5H_CLAUDE_ENABLED=true`, enables the workflow and starts a due check.
For optional cloud Codex, `-Codex` (Windows) / `--codex` verifies and uploads a
dedicated ChatGPT-managed auth.json and sets `L5H_CODEX_ENABLED=true`. Secrets
and repository variables are not inherited from the public template. Review
every code change in the private deployment before allowing it to use secrets.

The workflow runs on the default branch only. Provider jobs are read-only and
separate; a fresh state-save job alone gets `contents: write`. Third-party action SHAs and CLI versions are pinned. Review
updates before changing them. Scheduled workflows can be disabled by GitHub
for inactivity or other account/repository conditions; check Actions regularly.
Private-repository Actions minutes and overage charges vary by GitHub plan; no
fixed monthly cost guarantee is made.

## Configuration

`config.env` is local and ignored by Git. `cloud.env` is the public source
template and keeps both cloud providers off. Both are data-only KEY=VALUE files;
unknown keys are ignored. Private-deployment variables `L5H_CLAUDE_ENABLED` and
`L5H_CODEX_ENABLED` override the matching cloud switches.

| Key | Default | Meaning |
|---|---|---|
| INTERVAL_MINUTES | 301 | Minimum minutes since last successful ping; clamped to 300–525600. |
| CLAUDE_ENABLED | false | Public-template default; private setup enables Claude with a repository variable. |
| CLAUDE_MODEL | haiku | Claude model alias or ID. |
| CLAUDE_PROMPT | ok | Keep it short. |
| CLAUDE_BIN | empty | Explicit executable path; otherwise search common locations. |
| CODEX_ENABLED | false | Enable Codex. |
| CODEX_MODEL | empty | Codex CLI built-in default; user config is intentionally ignored. Set a lightweight model available on your plan. |
| CODEX_PROMPT | ok | Keep it short. |
| CODEX_BIN | empty | Explicit executable path. |
| CODEX_REASONING_EFFORT | low | Must be supported by the selected model. |
| LOG_RETENTION_DAYS | 30 | Prune old monthly keepalive log files; 0 disables pruning. |
| QUIET_HOURS | empty | Local time HH:MM-HH:MM; GitHub runners use UTC. |

Claude runs with safe mode, restricted mode, no built-in tools and no MCP.
Codex uses read-only sandboxing, ignores user config/rules and disables project
document loading. Codex still has its built-in tools; do not use untrusted prompts.
Managed CLI policies may still apply. Each CLI invocation is bounded to about
120 seconds; a failed provider does not discard another provider's success.

## Status and manual checks

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File bin\keepalive.ps1 -Status
powershell -NoProfile -ExecutionPolicy Bypass -File bin\keepalive.ps1 -DryRun
# Only when an immediate real message is wanted:
powershell -NoProfile -ExecutionPolicy Bypass -File bin\keepalive.ps1 -Force
```

```sh
./bin/keepalive.sh --status
./bin/keepalive.sh --dry-run
./bin/keepalive.sh --force
# Cloud timestamps from this checkout (fetch current state first if needed):
L5H_STATE_FILE=state/cloud-state.env ./bin/keepalive.sh --config cloud.env --status
gh run list --workflow keepalive.yml -L 5
```

Estimated window end = last ping + five hours, **not a provider-reported reset**.
Use the provider's Usage page for actual limits. `--force` ignores both interval
and quiet hours; it does not reset a live window. Bash `--due` exits 0 if due,
3 if nothing is due, and 2 for invalid CLI arguments/config paths. `--enabled`
prints the enabled providers. Normal execution exits 1 on provider/state failure.

## Troubleshooting and removal

If the laptop shows console flashes or sleep disruption, stop local automation:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install\disable-local-windows.ps1
```

This keeps the task disabled, removes wake permission, and preserves login and
configuration. Neither the installer without `-EnableLocal` nor the CLI setup
helper can silently enable it again. It does not diagnose display/HDR changes.

A green GitHub run can mean only “nothing due.” Inspect the **Ping** step and
saved timestamps to verify an actual message. CLI errors intentionally withhold
raw output to keep credentials out of Actions logs. Check `claude auth status` /
`codex login status` locally, installed CLI versions, and model availability.
A failed ping is retried at the next scheduler check; no tight retry loop is used.

```powershell
powershell -ExecutionPolicy Bypass -File install\uninstall-windows.ps1
```

```sh
./install/uninstall-unix.sh
# Cloud:
gh workflow disable keepalive.yml
```

Local uninstall keeps configuration, state and CLI logins. Disabling a workflow
does not revoke its credentials. See [SECURITY.md](SECURITY.md) for revocation.

## Development

```sh
python -m unittest discover -s tests -v
```

Tests use fake CLIs and temporary directories, never real AI accounts. The test
workflow covers Windows, Linux and macOS. Runtime scripts live in `bin/`,
installers in `install/`, and agent instructions in identical `AGENTS.md` and
`CLAUDE.md`. Local logs, credentials and instruction backups are git-ignored.

MIT — [LICENSE](LICENSE). Not affiliated with Anthropic or OpenAI.
