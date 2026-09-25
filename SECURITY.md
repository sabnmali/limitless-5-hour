# Security

## What this project touches

It runs two official CLIs with a one-word prompt on a timer. It has no server,
no database, no web interface, no user accounts and no network listener of its
own. That removes most of the usual attack surface, but two things do matter:
**a credential for your AI subscription**, and **a scheduled job that can run
commands on your behalf**.

The public repository is source code only. Cloud use requires a separate
**private deployment repository** created from the template. This is mandatory
for ChatGPT-managed Codex authentication: OpenAI's official guidance says not
to use auth.json automation in public or open-source repositories.

## Where credentials live

| | Stored | Visible to |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | Private deployment repository secret | only the isolated Claude job at run time; nobody can read it back through GitHub |
| `CODEX_AUTH_JSON` | Private deployment repository secret | only the isolated Codex job |
| `CODEX_SECRET_UPDATE_TOKEN` | Private deployment repository secret | only the post-container persistence step; repository-scoped Secrets: write, so it can replace any repo-level Actions secret but cannot read values |
| `L5H_GITHUB_DISPATCH_TOKEN` | Netlify production Functions environment | dispatcher; repository-scoped Actions: write, optionally Contents: read-only |
| Local CLI login | Whatever the CLI itself uses (`claude auth login`) | your machine only |

The setup scripts hold the token in memory and pipe it straight into
`gh secret set`. It is never written to a file and never passed as a
command-line argument, so it does not land in your shell history or the
process list. Input is read with the echo turned off, so pasting it does not
put it on screen a second time.

What that cannot protect: `claude setup-token` prints the token once, by
design. If your terminal is being recorded or its scrollback is shared, the
token is in it. Revoke and reissue if that happens.

Never commit secrets. The repository ignores local credentials and instruction
backups; review staged files before publishing. `config.env` is git-ignored.
The public template's `cloud.env` disables both providers and its state starts at
zero. A private deployment commits only settings and ping timestamps; those
timestamps reveal approximate use times to people who can access that private repo.

## Revoking access

Removing the scheduler is not the same as revoking the credential. To fully cut
access:

```bash
# 1. stop the job
gh workflow disable keepalive.yml

# 2. delete the stored credentials
gh secret delete CLAUDE_CODE_OAUTH_TOKEN
gh secret delete CODEX_AUTH_JSON
gh secret delete CODEX_SECRET_UPDATE_TOKEN

# 3. revoke the token itself, so it is dead even if a copy leaked
#    Claude: https://claude.ai/settings  ->  revoke the Claude Code token
#    Codex: use account security/session controls to revoke access.
#    `codex logout` removes local credentials; do not assume it revokes copied tokens.
```

Step 3 is the one that actually matters. Steps 1 and 2 only stop *this*
repository from using it.

For the optional Netlify dispatcher, also disable its production scheduled
function and revoke its dedicated GitHub token. It gets no AI credentials.
The separate Codex update token must never be supplied to Netlify. See
[NETLIFY.md](NETLIFY.md) for its access scope and login isolation requirements.

For a local install, `install/uninstall-*` removes the scheduler; the CLI stays
logged in until you run `claude auth logout`.

## Noticing when something is wrong

Check GitHub Actions and configure your workflow-failure notifications.
Notification delivery depends on your GitHub settings. A green no-op run is
not proof that the CLI works; inspect the Ping step and saved timestamps.
Displayed window boundaries are estimates, not provider-reported reset times.

Two guards limit the damage from a misconfiguration:

- `INTERVAL_MINUTES` is floored at 300 in code, so a typo like `1` cannot turn
  the job into a loop that burns your quota.
- Only keys the scripts actually define are read from a config file. A config
  cannot reassign `PATH`, the state file location, or any other internal.

Private-repository overage costs depend on your plan and job durations. AI pings still
consume subscription usage; enabled paid extra usage can have monetary costs.

## Hardening already applied

- Workflow triggers are `schedule` and due-only `workflow_dispatch`; there is no
  input that can bypass the 300-minute floor. Pull requests cannot run a
  secret-bearing job.
- Claude and Codex run in separate fresh jobs. A provider CLI never receives the
  other provider's credential. Codex additionally runs inside a pinned,
  disposable container, which exits before its credential-persistence token is
  exposed on the host. A third fresh job, which runs no provider code, receives
  the short-lived `contents: write` token and commits timestamps.
- Default workflow permission is `contents: read`; only the state-save job gets
  `contents: write`.
- Third-party actions are pinned to commit SHAs, not tags, because a tag can be
  repointed at different code. Dependabot proposes updates monthly so the pins
  do not silently rot.
- Log output is passed through a redactor that masks anything token-shaped
  before it can reach a log file or an Actions log. This is a secondary
  safeguard, not a promise to recognize every possible secret format.
- Raw CLI error output is withheld rather than relying on token-pattern masking.
- CLI versions are pinned in the cloud workflow; npm package publishers remain
  part of the supply-chain trust boundary.
- Claude runs in safe/restricted mode with tools disabled; Codex ignores user
  configuration and project documents and uses read-only sandboxing. Managed
  policies still apply.
- Run locks prevent concurrent pings; each CLI has a bounded runtime.
- The offline regression workflow never receives AI credentials and uses a
  read-only GitHub token, including for pull requests.
- `.sh` files are `text eol=lf` in `.gitattributes`, so a CRLF checkout cannot
  turn a script into something that fails open.

## Deliberately out of scope

The CLI core has no database, no HTTP endpoints, no HTML rendering, no file
uploads, no cookies and no password storage, so SQL injection, XSS, CORS,
security headers, upload limits, session flags and password hashing have no
surface to apply to here.

The optional Netlify deployment has a static information page and a private
scheduled function. It validates the repository, uses a fixed GitHub origin,
refuses redirects, bounds the request time and withholds upstream error bodies.
Its optional state read only extracts one numeric `NEXT_DUE` value and fails
open (dispatches) on any error, so it can skip a check but never add a ping.
Its public page does not expose health, tokens or provider usage.

## Reporting a problem

Use GitHub's private vulnerability reporting on the public source repository.
For non-sensitive bugs, open an issue. Never include a token or any part of one.
