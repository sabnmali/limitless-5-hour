---
name: no-5-hour-limit
description: Inspect or control the No 5-Hour Limit keepalive - the local or GitHub Actions job that pings the Claude and Codex CLIs every ~5 hours to send scheduled minimal prompts; reset times are only estimates. Use when the user asks about their 5-hour limit/window, "kotam ne zaman yenilenir", "limitim ne durumda", "keepalive", "pencere ne zaman bitiyor", or wants to start/stop/check the keepalive, fire a ping now, or read its logs.
---

# No 5-Hour Limit

A scheduled job that sends a tiny prompt to the Claude CLI (and optionally the
Codex CLI) once every `INTERVAL_MINUTES` (default 301 = 5 h + 1 min). A ping may start an idle usage window. It cannot reset a live window or
initialize every model-specific counter. Normal ChatGPT chat has separate
allowances and is not supported by this CLI integration.

## Locating the install

The repository root is wherever the user cloned it. Find it in this order:

1. `NO_5H_LIMIT_HOME` environment variable, if set.
2. The path recorded in `~/.no-5-hour-limit-path` (written by the installer).
3. Ask the user.

Set `REPO` to that path before running the commands below.

## Commands

All of these are read-only or user-initiated; none of them need approval
beyond the normal Bash permission prompt.

**Windows**

```
powershell -NoProfile -ExecutionPolicy Bypass -File "<REPO>\bin\keepalive.ps1" -Status
powershell -NoProfile -ExecutionPolicy Bypass -File "<REPO>\bin\keepalive.ps1" -Force
powershell -NoProfile -ExecutionPolicy Bypass -File "<REPO>\install\install-windows.ps1" -EnableLocal
powershell -NoProfile -ExecutionPolicy Bypass -File "<REPO>\install\uninstall-windows.ps1"
```

**macOS / Linux**

```
"<REPO>/bin/keepalive.sh" --status
"<REPO>/bin/keepalive.sh" --force
"<REPO>/install/install-unix.sh"
"<REPO>/install/uninstall-unix.sh"
```

## When it runs in the cloud

If `<REPO>/.github/workflows/keepalive.yml` exists and the repo has a remote,
the keepalive may be running on GitHub Actions instead of (or as well as) this
machine. In that case the authoritative state is `state/cloud-state.env` in the
private deployment repo, not `state/state.env`. Never store subscription
credentials in the public source template:

```
git -C "<REPO>" fetch origin
git -C "<REPO>" show origin/HEAD:state/cloud-state.env
L5H_STATE_FILE="<REPO>/state/cloud-state.env" bash "<REPO>/bin/keepalive.sh" --config "<REPO>/cloud.env" --status
```

`L5H_STATE_FILE` must be absolute here - it is resolved against the current
directory, not the repository.

To run the normal due check, or to check recent runs:

```
gh workflow run keepalive.yml -R <owner>/<private-repo>
gh run list --workflow keepalive.yml -L 5 -R <owner>/<repo>
```

Settings live in `cloud.env`; provider enablement in a private deployment uses
`L5H_CLAUDE_ENABLED` / `L5H_CODEX_ENABLED` repository variables. `config.env`
only affects the local scheduler. The cloud workflow deliberately has no force
input because its restricted Netlify token can dispatch it.

## Answering common questions

| User asks | Do this |
|---|---|
| "When does my window reset?" / "Kotam ne zaman yenilenir?" | Run `--status` / `-Status` and report the estimated window end and next ping, explicitly labeling them estimates. Use the provider Usage page for actual reset times. |
| "Is it running?" | `--status` shows the scheduler row: installed / NOT INSTALLED. |
| "Start a window now" | Run with `--force` / `-Force`. It sends a message immediately; it does not reset a window that is already open, so it only helps once the previous one has expired. |
| "It isn't working" | Read the newest file in `<REPO>/logs/`. The most common cause is `not logged in` - the fix is `claude auth login` (or `codex login`). |
| "Turn it off" (local) | Run the uninstall script. It only removes the scheduler entry; config and logs stay. |
| "Turn it off" (cloud) | `gh workflow disable keepalive.yml`. The local uninstaller does not stop GitHub Actions. To revoke the credential too, follow SECURITY.md. |
| "Also keep Codex alive" | Set `CODEX_ENABLED=true` in `<REPO>/config.env` locally. For cloud, follow NETLIFY.md and enable `L5H_CODEX_ENABLED` only in the private deployment after its dedicated credentials exist. |
| "Does it work when my PC is off?" | Only if the GitHub Actions workflow is set up. Check `gh run list --workflow keepalive.yml`. |

## Editing settings

`<REPO>/config.env` is a plain `KEY=VALUE` file. Keys:
`INTERVAL_MINUTES`, `CLAUDE_ENABLED`, `CLAUDE_MODEL`, `CLAUDE_PROMPT`,
`CLAUDE_BIN`, `CODEX_ENABLED`, `CODEX_MODEL`, `CODEX_PROMPT`, `CODEX_BIN`,
`CODEX_REASONING_EFFORT`, `LOG_RETENTION_DAYS`, `QUIET_HOURS`.

Changes take effect on the next scheduler tick - no restart needed.

## Cautions

- `--force` spends a little quota; it does not reset or consume an entire window. Only run it when requested.
- Prefer local Codex to avoid copied cloud refresh credentials becoming stale.
- Fetching does not update the local state file; use the fetched file for cloud status.
- A workflow file or green no-op run alone does not prove the cloud scheduler works.
- Do not lower `INTERVAL_MINUTES` below 300: pinging inside a live window
  wastes it without opening a new one.
