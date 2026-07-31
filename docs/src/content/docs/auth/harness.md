---
title: Agent harness credentials
description: The account pool, OAuth refresh, quota rotation, the credentials-owner marker — and the undocumented vendor internals the whole thing is built on.
sidebar:
  order: 2
---

Zimmer keeps a pool of vendor accounts and rotates between them when one hits its rate limit.
That's the feature. Underneath it is the most fragile machinery in the project, and it's fragile for
a reason that isn't Zimmer's fault.

:::danger[This is built on an undocumented, moving target]
`docs/CLAUDE_CODE_OAUTH_ASSUMPTIONS.md` (now folded into this page and
[Known limitations](/limitations/)) exists because Zimmer automates OAuth token management on top
of Claude Code's OAuth implementation, which is an undocumented internal. Every constant below (the
token endpoint, the CLI's client ID, the file paths, the on-disk JSON shape, the login prompt text)
is a fact about someone else's private implementation that can change without notice.

The assumptions doc was last verified against CLI `2.1.177` on 2026-06-14. Two production
outages caused by exactly this are written up in the source.
:::

## The model

`ClaudeAccount` is the pool for both runtimes, discriminated by a `runtime` column
(`claude_code` | `codex`). The naming is a leftover.

Everything goes through `RuntimeAuthProvider.for(runtime)` → `ClaudeAuthProvider` or
`CodexAuthProvider`.

| | Claude | Codex |
| --- | --- | --- |
| Token endpoint | `platform.claude.com/v1/oauth/token` | `auth.openai.com/oauth/token` |
| Client ID | `9d1c250a-e61b-44d9-88ed-5944d1962f5e` (the CLI's public ID) | `app_EMoamEEZ73f0CkXaXp7hrann` |
| Files | `~/.claude.json` (identity), `~/.claude/.credentials.json` (tokens) | `~/.codex/auth.json` |
| Token TTL | from `expiresAt` (~8h, inferred) | 24h, inferred — `auth.json` has no expiry field |
| Rotation | `AccountRotationService`, 5-minute interval | inline in the provider, 24h |
| Identity check on capture | email must match | none |

## The refresh loop

`RefreshRuntimeAuthTokensJob` runs every 5 minutes:

```mermaid
sequenceDiagram
    participant C as Cron (*/5)
    participant P as RuntimeAuthProvider
    participant FS as Filesystem
    participant DB as Postgres
    participant V as Vendor (Anthropic/OpenAI)

    C->>P: for each registered provider
    P->>FS: reconcile_filesystem_identity!
    Note over P,FS: adopt a manual `claude /login` switch into the DB
    P->>FS: sync_current_account_tokens!
    Note over P,FS: the CLI refreshes tokens on its own, mid-session —<br/>scrape them back or our DB copy goes stale
    P->>DB: needs_reauth_recovery_candidates
    P->>V: recover_needs_reauth (probe refresh)
    P->>DB: accounts_needing_refresh<br/>(expiring within 15 min)
    loop each account, under row lock
        P->>V: POST /oauth/token (grant_type=refresh_token)
        alt 2xx
            V-->>P: new access + NEW refresh token
            P->>DB: persist BOTH atomically
            P->>FS: write to disk IF this account is current
        else 401 / invalid_grant
            P->>DB: status = needs_reauth
        else transient
            P->>C: re-enqueue with backoff (2/4/8 min, max 3)
        end
    end
```

The refresh threshold is 15 minutes on a 5-minute cron — three chances to catch a token before it
expires.

### Refresh tokens are single-use and rotating

Every refresh returns a new refresh token and invalidates the old one — *and* invalidates the
sibling access token. Two consequences the code has to defend against:

1. The new pair must be persisted atomically. A crash between "got new tokens" and "wrote them"
   bricks the account. `refresh_token!` writes both in one `update!`.
2. A future `expiresAt` is not proof a token is live. If someone else refreshed, your
   still-unexpired access token is already dead. The code does *not* enforce this — `token_expired?`
   still keys purely off `expiresAt`. The defense is the completeness invariant.

A credential set with no refresh token is a dead end. `ClaudeAccount.complete_claude_oauth?`
refuses to persist or adopt one, because the CLI sometimes rewrites `.credentials.json` *without* the
`claudeAiOauth` block at all, and adopting that blindly would brick the whole pool.

## The credentials-owner marker

Here is the structural problem the marker solves.

In the deployment shape this code was written for, `~/.claude.json` (identity) is container-local
while `~/.claude/.credentials.json` (tokens) is a shared bind-mount. So any code that reads the
local identity file to decide *who owns the shared tokens* gets a confidently wrong answer on the
wrong container. That is the root cause of the 2026-06-11 cross-account token-contamination outage.

The fix: a marker file, `~/.claude/.ao-credentials-owner.json`, written next to the shared tokens,
recording which account they belong to. `filesystem_credentials_owned_by_self?` gates the sync.

:::caution[The docs and the method's own docstring both describe a fallback that doesn't exist]
`docs/AUTH_ROTATION_ARCHITECTURE.html` (invariant I2) and the docstring on
`ClaudeAccount#sync_tokens_from_filesystem!` both claim there is a *"legacy `~/.claude.json` fallback
while no marker exists yet."*

There isn't. `filesystem_credentials_owned_by_self?` returns `false` when the marker is absent and
refuses to sync, and its own comment says so, explicitly contradicting the docstring 100 lines above
it. The private method is correct; the doc and the docstring are stale.
Tracked in [#59](https://github.com/tadasant/zimmer/issues/59).
:::

## Rotation on quota

When an account hits its rate limit, Zimmer rotates to the next one by priority:

1. Sync the outgoing account's tokens off disk.
2. Snapshot its quota state.
3. `mark_quota_exceeded!`.
4. `activate_next_account` — which validates the candidate by calling `refresh_token!` before
   activating it, so a broken account is skipped before it can brick the pool.
5. Write the new account's config and credentials to disk, stamp the owner marker.
6. Record an `AccountRotationEvent`.

`QuotaResetCheckerJob` (every 15 min, **Claude only**) restores `quota_exceeded` accounts when either
window's reset time has passed, or utilization drops below 100%. It then calls
`AuthOutageParkService.wake_parked_sessions!` so the sessions that were blocked on those accounts
resume in the same sweep — see [When the pool runs dry](#when-the-pool-runs-dry).

### What `/quotas` reports for the pool

Anthropic meters two windows per account, 5-hour and 7-day, and the page shows both — per account,
and averaged across the pool.

The pool's 5-hour average is labelled **"Avg 5-Hour Utilization (effective)"** because it is not a
plain average of the 5-hour counters. An account whose 7-day window is spent — status `rejected`, or
the counter at its cap — cannot serve a request however much 5-hour headroom it reports, so it counts
as 100% in that average, and its card says *"Counted as 100% in the pool figure"* under the 5-hour
bar. An account at 29% on 5 hours and 100% on the week would otherwise pull the headline down and
advertise pool headroom that nothing can spend.

The correction runs one way. The 7-day average takes the 7-day counters as they are, because the
weekly window subsumes the 5-hour one: an account at its 5-hour cap is idle for minutes and then
serves again. A window whose reset time has passed reads as 0% on both axes, since the sliding window
has cleared and the last number Zimmer recorded for it is stale.

Two vocabularies of "spent" now coexist, and they disagree at one edge. `QuotasHelper` reads the API
status (`allowed` and `allowed_warning` serve; anything else blocks); `QuotaResetCheckerJob.window_clear?`,
which decides whether to restore a `quota_exceeded` account, ignores status and looks only at reset
time and utilization. A snapshot with status `rejected` at 50% utilization is therefore *spent* to the
page and *clear* to the healer. The healer governs account state; the page governs what you read.

`pool_utilization_5h` itself is display-only — no scheduler or rotation path reads it. The underlying
snapshot numbers are not: `QuotaResetCheckerJob` and `QuotasController#auto_heal_accounts` both flip
accounts back to `active` from them. Rotation picks from `ClaudeAccount.available` (status `active`)
and applies no quota test of its own, which is why an account that is 7-day-spent but was never
current stays a rotation candidate — see [#248](https://github.com/tadasant/zimmer/issues/248).

:::danger[Rotation is triggered by matching an English error string]
`ApiErrorRetryService::ACCOUNT_QUOTA_LIMIT_PATTERN`:

```ruby
/hit your\b.*\blimit\b.*\bresets\b/i
```

That regex, run against the **transcript message text**, is the sole trigger for the entire
multi-account rotation feature. That trigger is Anthropic's prose: a regex over transcript text,
with no HTTP status or structured error code behind it.

On 2026-06-14 the CLI changed "hit your limit" to "hit your session limit," which the regex
happens to still match. A previous wording change did not, and rotation silently stopped firing.
The session fell through to the transient-rate-limit path, retried six times against an
already-capped account, exhausted its retries, and failed, with no log line saying rotation should
have fired. The failure mode is silent.
Tracked in [#53](https://github.com/tadasant/zimmer/issues/53).
:::

## Mid-run auth loss

`AuthRecoveryService` watches the transcript for `"Not logged in · Please run /login"` (matched by
`/not logged in|please run\s*\/login/i`), re-injects credentials to disk, and re-spawns the process.
Bounded by `MAX_RECOVERY_ATTEMPTS` attempts within `CONSECUTIVE_WINDOW` (15 minutes); returns
`:unrecoverable` if no account is available.

The bound is **time-based, not success-based**, and that distinction is the whole reason the service
terminates. A re-spawned Claude Code process spends its first 10–15 seconds connecting MCP servers
before it makes the API call that reports "Not logged in", so it clears any short liveness check
even when the credentials on disk are dead. Treating that liveness as recovery success — and
resetting the attempt counter on it — made the counter oscillate `0 → 1 → 0`, so
`MAX_RECOVERY_ATTEMPTS` could never be reached. Production session 684 logged
`retrying 1/3` **115 times over 35 minutes**, re-spawning the CLI into the same auth wall roughly
every 18 seconds, and surfaced nothing to the user but a wall of `Not logged in · Please run /login`.
Attempts now accumulate and are only forgiven by elapsed time, so an unrecoverable identity costs
three re-spawns instead of an unbounded loop.

## When the pool runs dry

Two exits mean Zimmer has no runway left: a quota hit with no rotation target
(`AccountRotationService#rotate!` → `{ success: false, reason: "no_available_accounts" }`), and auth
recovery that cannot succeed. Both route to `AuthOutageParkService`, which:

1. Writes a session log naming the outage and the retry time.
2. Sends a push notification.
3. Records `auth_outage_reason` / `auth_outage_parked_at` / `auth_outage_retry_at` on the session,
   which renders the amber outage banner on the session page.
4. Creates a one-time wake-up trigger — the same `reuse_session` + `last_session_id` shape the
   `wake_me_up_later` MCP tool uses. Creating the trigger is what puts the session to sleep, so the
   session lands in `waiting` rather than `needs_input`, and the heartbeat sweep anchors its cadence
   instead of nudging it back into the same wall.

The retry time is derived from the quota snapshots rather than a blind timer. `QuotaResetCheckerJob`
clears an account only when **both** windows are clear, so an account frees up at the later of its
two future resets and the pool frees up at the earliest such account; `RESET_BUFFER` (2 min) is
added, and the result is clamped between `MIN_RETRY_DELAY` (5 min) and `MAX_RETRY_DELAY` (12 h). An
auth outage has no published reset clock, so it uses `DEFAULT_RETRY_DELAY` (1 h).

For a **quota** park the trigger is only the backstop: `QuotaResetCheckerJob` usually restores the
accounts first and wakes those sessions in the same sweep, and only for a runtime that has an
available account again, so a session is never woken into the pool that was still empty.

An **auth** park gets no such fast path, and the asymmetry is deliberate. "An account is available"
is evidence for a quota park — the pool was empty and now is not. It is no evidence at all for an
auth park, which is reached precisely when an account *was* available and the runtime rejected its
credentials anyway. Waking on it would resume the session into the identical failure every 15
minutes. Those sessions wait for their scheduled retry, which gives `RefreshRuntimeAuthTokensJob`
time to actually repair the identity.

## Logging in from the UI

The "Authenticate" button drives a PTY-screen-scraping flow:

```mermaid
sequenceDiagram
    participant U as You (browser)
    participant W as Web (QuotasController)
    participant DB as RuntimeLoginAttempt
    participant J as RuntimeLoginJob (worker)
    participant CLI as claude / codex (PTY)

    U->>W: POST /quotas/login (start)
    W->>DB: create attempt (status: starting)
    W->>J: enqueue RuntimeLoginJob
    J->>CLI: PTY.spawn("claude auth login --claudeai")<br/>CLAUDE_CONFIG_DIR = scratch dir
    CLI-->>J: terminal output
    J->>J: strip ANSI, match URL_REGEX
    J->>DB: write verification_url (status: awaiting_user)
    U->>W: poll GET /quotas/login/:id
    W-->>U: show the URL
    U->>U: authorize in the browser, copy the code
    U->>W: POST /quotas/login/:id/code
    W->>DB: write pasted_code
    Note over J,DB: job polls DB with .uncached —<br/>the AR query cache would hide<br/>a cross-process write
    J->>CLI: write code to stdin
    CLI->>CLI: writes .credentials.json to scratch
    J->>J: credentials_ready?(scratch)
    J->>DB: capture! — email must match, tokens must be complete
    U->>W: click "Switch" → provider.activate!
```

`RuntimeLoginAttempt` is being used as a cross-container message bus: the web process writes
`pasted_code`, the worker process reads it. That's why `poll_state` must use
`RuntimeLoginAttempt.uncached` — ActiveRecord's per-request query cache would otherwise hide the
write. It's documented at length in the code, and it's a landmine.
Tracked in [#111](https://github.com/tadasant/zimmer/issues/111).

:::caution[The login flow is screen-scraping a TUI]
The command string (`claude auth login --claudeai`), the authorize-URL host regex, and the literal
prompt `/Paste code here/i` are all hardcoded. `ClaudeLoginDriver` even hardcodes
`/home/rails/.local/bin/claude` as its first binary candidate. If Claude Code changes any of these,
login breaks wholesale.

Codex is the same story, with `codex login --device-auth` and a device-code regex
(`/\b([A-Z0-9]{4}-[A-Z0-9]{4,8})\b/`) tuned to an *observed* 4–5 character split.
:::

:::caution[One credential file, two writers]
`ClaudeAccount#write_credentials_to_filesystem!` does a whole-file overwrite of
`~/.claude/.credentials.json`. `ClaudeMcpCredentialWriter` read-merges an `mcpOAuth` map into the
*same* file.

So an account rotation replaces the file with account B's stored blob — dropping any `mcpOAuth`
entries written after B's blob was last captured. It self-heals (the injector rewrites `mcpOAuth`
on the next spawn), but it's an undeclared coupling between two subsystems that don't know about each
other.
:::
