# Independent cloud scheduling

Netlify wakes a **private deployment repository's** GitHub Actions every thirty
minutes. The public template never receives subscription credentials. Actions still enforces the
301-minute interval and serializes runs. Netlify never receives AI credentials.
This removes dependence on GitHub's cron delivery, not GitHub runner availability
or the providers' quota rules. No component guarantees an always-open window.

1. Import this repository into Netlify, using the default branch and netlify.toml.
   Only the published production deployment runs scheduled functions.
2. Create a fine-grained GitHub token restricted to this repository with
   **Actions: read and write**. Do not use your account-wide CLI token.
3. In Netlify, store it as **L5H_GITHUB_DISPATCH_TOKEN**, restricted to Functions
   and production. Set **L5H_GITHUB_REPOSITORY** to your `owner/repo` and
   **L5H_GITHUB_BRANCH** to the default branch. Redeploy after changing variables.
4. Use Functions > dispatch > Run now. Confirm a new workflow_dispatch run in
   GitHub Actions, then confirm a later scheduled invocation without your PC.
   HTTP 204 means GitHub accepted dispatch, not that a provider was pinged.
5. Set the private repository Actions variable `L5H_NETLIFY_PRIMARY=true`. This
   suppresses duplicate half-hour GitHub cron polls while retaining a daily
   GitHub health check.
6. Check Netlify function failures and GitHub Actions failures. Renew the token
   before its expiry. Stay within your Netlify plan; there are about 1,440
   invocations per 30 days. State-only commits are skipped by the build ignore rule.

No new npm dependencies or public trigger endpoint are used. GitHub cron can
remain as fallback because all dispatches use the same lock and state.

Netlify makes 48 checks per day instead of 288 at five-minute intervals.
Checks do not send AI prompts unless due. Polling can add up to fifteen minutes
after the 301-minute threshold on average and thirty minutes at worst, plus any
platform scheduling or runner delay.
These checks are internal operations, not user notifications.

## Cloud Codex credentials

Cloud Codex needs its own subscription login in a private deployment repository,
not a copy of a desktop session. OpenAI says this auth.json pattern is only for
trusted private automation and must not be used in public/open-source repos:
https://learn.chatgpt.com/docs/auth/ci-cd-auth

Use a separate `CODEX_HOME` outside the repository. Put
`cli_auth_credentials_store = "file"` in that home's `config.toml`, then run
`codex login` there interactively. Continue only when auth.json has
`auth_mode: "chatgpt"` and a refresh token; setup-cloud verifies both without
printing them. Never commit the file and remove the disposable local copy after
upload.

Windows PowerShell example (replace `OWNER/PRIVATE-REPO`):

```powershell
$env:CODEX_HOME = Join-Path $HOME '.codex-limitless-cloud'
New-Item -ItemType Directory -Force -Path $env:CODEX_HOME | Out-Null
Set-Content -LiteralPath (Join-Path $env:CODEX_HOME 'config.toml') -Value 'cli_auth_credentials_store = "file"'
codex login
gh secret set CODEX_SECRET_UPDATE_TOKEN --repo OWNER/PRIVATE-REPO
powershell -ExecutionPolicy Bypass -File install\setup-cloud-windows.ps1 -Repo OWNER/PRIVATE-REPO -Codex
```

macOS / Linux example:

```sh
export CODEX_HOME="$HOME/.codex-limitless-cloud"
mkdir -p "$CODEX_HOME"
printf '%s\n' 'cli_auth_credentials_store = "file"' > "$CODEX_HOME/config.toml"
codex login
gh secret set CODEX_SECRET_UPDATE_TOKEN --repo OWNER/PRIVATE-REPO
./install/setup-cloud.sh --repo OWNER/PRIVATE-REPO --codex
```

A second fine-grained token, restricted to this repository with **Secrets: read
and write**, must be stored as **CODEX_SECRET_UPDATE_TOKEN in GitHub only**.
The workflow saves auth.json back to CODEX_AUTH_JSON after each invocation,
including failures, so normal refresh rotation survives the ephemeral runner.
GitHub cannot scope this permission to a single secret: the token can replace
other repository secrets. It cannot read secret values back. Review that access
before creating it. Do not give this second token to Netlify.

Create the update token and dedicated login first. The setup command uploads
that login as `CODEX_AUTH_JSON` and sets the private repository's
`L5H_CODEX_ENABLED=true` Actions variable. If any Codex prerequisite or upload
fails, setup stops instead of reporting a Claude-only installation as complete. Verify a cloud Codex
turn before disabling its local scheduler. Revocation, login expiry,
provider policy changes or a failed secret write can still require signing in
again. A copied desktop login is not made safe merely by persisting it here.

## Provider-native scheduling

[Claude Routines](https://code.claude.com/docs/en/routines) run in Claude's cloud
but create full agent sessions and have routine limits. They are an alternative
scheduler, not proof that every Claude model counter starts.
[ChatGPT scheduled tasks](https://help.openai.com/en/articles/10291617-scheduled-tasks-in-chatgpt)
and Codex automations are separate. Scheduling a ChatGPT task is not a supported
way to start every ChatGPT and Codex allowance together.

## Disable and revoke

Pause/delete the Netlify production deployment's scheduled function or remove
the project, then revoke its dedicated GitHub token. Disable keepalive.yml to
stop the fallback too. For Codex, revoke its dedicated login and secret-update
token and remove CODEX_AUTH_JSON and CODEX_SECRET_UPDATE_TOKEN. Deleting secret
storage alone is not revocation.
