# Codex Authentication & Account Pooling

How Agent Orchestrator authenticates the **OpenAI Codex CLI** and pools Codex
accounts for rotation. This mirrors the Claude Code login-credential system: AO
keeps a pool of accounts, keeps the active account's credentials fresh, and
writes them to the CLI's canonical filesystem location before each spawn.

> **Treat Codex credentials like passwords.** `~/.codex/auth.json` and the
> `oauth_config` of a Codex `ClaudeAccount` row contain live access/refresh
> tokens (or an `OPENAI_API_KEY`). Never commit them, paste them into tickets,
> or share them.

## Where Codex auth lives

`CodexAuthProvider` (`app/services/codex_auth_provider.rb`) is the
`RuntimeAuthProvider` for the `"codex"` runtime. It owns every Codex-specific
constant:

| Constant | Value | Purpose |
|----------|-------|---------|
| `RUNTIME` | `"codex"` | Runtime identifier (the `runtime` column on `ClaudeAccount`) |
| `TOKEN_ENDPOINT` | `https://auth.openai.com/oauth/token` | OAuth refresh endpoint |
| `CLIENT_ID` | `app_EMoamEEZ73f0CkXaXp7hrann` | Codex CLI's OAuth client ID |
| `CODEX_HOME` | `$CODEX_HOME` or `~/.codex` | CLI home directory |
| `AUTH_JSON_PATH` | `$CODEX_HOME/auth.json` | Canonical credential file |
| `TOKEN_TTL` | `24.hours` | Soft expiry measured from `last_refresh` |
| `ROTATION_INTERVAL` | `24.hours` | How often the refresh sweep targets the Codex pool |

## The account pool

Codex accounts are **`ClaudeAccount` records with `runtime: "codex"`** — the same
table the Claude Code pool uses, scoped by the `runtime` column. There is no
separate model. Every pool query in Codex code paths is scoped via
`ClaudeAccount.for_runtime(CodexAuthProvider::RUNTIME)`, and every Claude-only
query is scoped to `claude_code`, so the two pools never cross-contaminate
(rotation, current-account flags, quota sweeps, and the quotas page all stay
runtime-isolated).

> Emails are **globally unique** across the pool, so a single email cannot have
> both a Claude and a Codex account. Use distinct emails per runtime.

### Two credential kinds

Codex authenticates one of two ways, both pooled identically:

1. **ChatGPT OAuth (preferred)** — captured via `codex login --device-auth`.
   The full `auth.json` envelope is stored under `oauth_config["auth_json"]`. AO
   refreshes these tokens against OpenAI's token endpoint and rotates between
   accounts when one hits a usage quota.
2. **`OPENAI_API_KEY` (fallback)** — a static key stored under
   `oauth_config["api_key"]`. API keys never expire and have nothing to refresh;
   AO simply writes them to `auth.json`.

`ClaudeAccount#codex_api_key_account?` returns `true` for the second kind (an
API key present and no refresh token). Such accounts are no-ops for refresh and
never expire.

## auth.json schema

The Codex CLI reads and writes `~/.codex/auth.json`. AO writes OAuth accounts'
stored envelope verbatim (preserving fields AO doesn't model) and writes API-key
accounts as a minimal `{ "OPENAI_API_KEY": "sk-..." }`.

```jsonc
{
  "OPENAI_API_KEY": "sk-...",        // present (may be null) for OAuth; the key itself for API-key logins
  "tokens": {                          // present for ChatGPT OAuth logins
    "id_token": "<raw JWT string>",
    "access_token": "<JWT string>",
    "refresh_token": "<string>",
    "account_id": "<ChatGPT account id | null>"
  },
  "last_refresh": "2026-05-29T12:00:00Z"  // ISO8601; drives AO's soft TTL
}
```

`id_token` is a **plain JWT string** on disk, not a nested object.

## Token lifecycle

- **Before a spawn** (`inject_for_session!`): AO reconciles the filesystem with
  the DB and writes the active account's credentials to `~/.codex/auth.json`. If
  the active account's tokens are expired or expiring, AO refreshes them first.
  This is the real freshness guarantee at spawn time.
- **At runtime**: the Codex CLI refreshes the active account's tokens in place
  and **rotates the refresh token** on each use, writing the new pair back to
  `auth.json`. AO syncs those filesystem tokens back into the DB (identity-gated
  on `account_id`) before refreshing, so it never replays a spent refresh token
  (which OpenAI rejects with `refresh_token_reused`).
- **Background sweep** (`RefreshRuntimeAuthTokensJob`): runs at the minimum
  cadence across runtimes, but Codex tokens only become "expiring soon" near the
  end of their 24h `TOKEN_TTL` window, so the vast majority of ticks are no-ops
  for Codex — it refreshes each account roughly once per day.

### Refresh contract

OAuth refresh is a `POST` to `TOKEN_ENDPOINT` with `Content-Type:
application/json` and body:

```json
{
  "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
  "grant_type": "refresh_token",
  "refresh_token": "<refresh token>"
}
```

On a 2xx, AO updates `tokens.id_token`/`access_token`/`refresh_token` **only for
fields the response includes** (matching the CLI's `persist_tokens`) and sets
`last_refresh` to now. A refresh is treated as **permanently failed** (account
marked `needs_reauth`) on HTTP 401 or when the error code is one of
`refresh_token_expired`, `refresh_token_reused`, `refresh_token_invalidated`.
Other failures are transient and retried by the dispatcher with backoff.

## Quota rotation

When a Codex session hits a usage quota, `CodexAuthProvider#rotate_for_quota!`
marks the current account `quota_exceeded`, activates the next available account
in priority order (validating its OAuth tokens by probing the refresh endpoint
first; API-key accounts skip the probe), writes the new credentials to
`auth.json`, and records an `AccountRotationEvent`. Unlike Claude, Codex does not
take Anthropic-style quota snapshots — there is no OpenAI quota API integration
yet, so the Codex pool relies on rotation alone.

## Managing Codex accounts (rake tasks)

All tasks live in `lib/tasks/codex_accounts.rake` and are scoped to the Codex
runtime — they never touch Claude Code accounts.

```bash
# All rails/rake commands run from the agent-orchestrator directory.

# Add a ChatGPT OAuth account (priority 0 = highest)
bin/rails 'codex_accounts:add[me@example.com,0]'
# Then on the worker, authenticate and capture the tokens:
#   codex login --device-auth   # as me@example.com
bin/rails 'codex_accounts:capture_tokens[me@example.com]'

# Add an API-key account
bin/rails 'codex_accounts:add_api_key[svc@example.com,sk-...,1]'

# Inspect / manage the pool
bin/rails codex_accounts:list
bin/rails 'codex_accounts:remove[me@example.com]'
bin/rails codex_accounts:clear_all   # removes only Codex accounts + their rotation events
```

`capture_tokens` reads the current `~/.codex/auth.json` and stores it on the
named account. Because `auth.json` carries no email, AO trusts that the file's
identity belongs to the email you pass — run `codex login` as the intended
account immediately before capturing.

## Related code

- `app/services/codex_auth_provider.rb` — the provider
- `app/services/runtime_auth_provider.rb` — the runtime seam (`.for`, `.registered`)
- `app/models/claude_account.rb` — pool model; Codex token logic dispatched on `codex?`
- `app/jobs/refresh_runtime_auth_tokens_job.rb` — the per-runtime refresh dispatcher
- `lib/tasks/codex_accounts.rake` — pool management tasks
