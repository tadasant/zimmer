# Claude Code OAuth — Our Assumptions About a Moving Target

> **Scope.** This document is about the OAuth login that authenticates the
> **Claude Code CLI itself** (the Max-subscription identity every agent session
> runs as) and the **account-rotation pool** Zimmer builds on top of it. It is **not**
> about MCP-server OAuth (BigQuery/Linear/Notion credentials) — that is a separate
> system documented in [`OAUTH_ARCHITECTURE.md`](OAUTH_ARCHITECTURE.md). For the
> Codex runtime equivalent, see [`CODEX_AUTH.md`](CODEX_AUTH.md). For the
> architecture and intended operation of the rotation system, see the rendered
> walkthrough [`AUTH_ROTATION_ARCHITECTURE.html`](AUTH_ROTATION_ARCHITECTURE.html).

## Why this document exists

Zimmer has built a complex OAuth-token + account-rotation automation **on top of
Claude Code's OAuth implementation, which is an undocumented, moving target.**
Anthropic can — and does — change how the CLI stores credentials, when it rotates
tokens, and what its login command looks like, with no notice and no changelog
for these internals.

Every time we debug an auth incident and discover that the CLI behaves
differently than we assumed, that discovery is expensive: it usually means a
production outage and hours of forensics. This document is the **durable record of
those assumptions** so the next investigation starts by *diffing observed behavior
against what is written here* instead of re-deriving everything from scratch.

**If you observe Claude Code behaving differently than documented below, update
this file in the same PR as your fix, and bump the "Observed with CLI version"
line.** A stale assumption that nobody wrote down is exactly how the 2026-06-11
outage (worked example at the bottom) happened.

- **Observed with Claude Code CLI version:** `2.1.177`
- **Last verified:** 2026-06-14

---

## 1. The two credential files (and the critical scope split)

Claude Code stores its login state in **two** files. Zimmer's entire rotation system
hinges on understanding what each one is and — critically — *where it lives in
production*.

| File | Holds | Production scope |
|------|-------|------------------|
| `~/.claude.json` | **Identity** + a lot of unrelated CLI state (project history, onboarding flags, MCP server config, etc.). The OAuth identity is the `oauthAccount` field. | **Container-local.** It lives in the container's home dir, *not* under the shared mount. The web and worker containers each have their own copy, and **they routinely disagree.** |
| `~/.claude/.credentials.json` | **Tokens only**: `{ "claudeAiOauth": { accessToken, refreshToken, expiresAt, scopes, subscriptionType } }` | **Shared.** In production `/home/deploy/.claude` is bind-mounted into both the web and worker containers at `~/.claude`, so this single file is shared by both. |

> ⚠️ **The single most important and least obvious fact in this whole system:**
> the **identity** file is per-container but the **tokens** file is shared. Any
> code that reads `~/.claude.json` to decide *"whose tokens are in
> `~/.claude/.credentials.json`?"* is comparing a container-local answer against a
> shared file — and on the "wrong" container it gets a confidently wrong answer.
> This is the structural root of cross-account token contamination. Zimmer works
> around it with a **shared owner marker** (`~/.claude/.ao-credentials-owner.json`,
> written by Zimmer alongside the credentials) — see the architecture doc.

### `~/.claude.json` → `oauthAccount` shape

Has appeared in **two** formats across CLI versions (Zimmer handles both — see
`ClaudeAccount#extract_oauth_email`):

```jsonc
// Legacy: plain string
"oauthAccount": "bob@tadasant.com"

// Current (2.1.x): Hash
"oauthAccount": { "emailAddress": "bob@tadasant.com", /* accountUuid, organization, ... */ }
```

### `~/.claude/.credentials.json` shape

```jsonc
{
  "claudeAiOauth": {
    "accessToken":  "sk-ant-oat01-…",   // ~108 chars
    "refreshToken": "sk-ant-ort01-…",   // ~108 chars
    "expiresAt":    1781219403762,        // ms since epoch
    "scopes":       ["user:inference", "user:profile", "user:sessions:claude_code",
                     "user:mcp_servers", "user:file_upload"],
    "subscriptionType": "max"
  }
}
```

---

## 2. OAuth endpoints, client, scopes (constants we depend on)

Mirrored in code as `ClaudeAuthProvider::*`. If any of these change, refresh and
login break wholesale.

| Thing | Value |
|-------|-------|
| Token endpoint | `https://platform.claude.com/v1/oauth/token` |
| OAuth client ID | `9d1c250a-e61b-44d9-88ed-5944d1962f5e` (the Claude Code CLI's public client ID) |
| Authorize URL host(s) | `https://claude.com/cai/oauth/authorize…` and `https://platform.claude.com/oauth/authorize…` |
| Redirect URI (paste flow) | `https://platform.claude.com/oauth/code/callback` |
| Login scopes (from authorize URL) | `org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload` |
| PKCE | `code_challenge_method=S256` |

---

## 3. Refresh-token behavior — **the assumption that bites hardest**

These are the rules Zimmer's rotation logic is built on. They are inferred from
observed behavior, not from a spec.

1. **Refresh tokens are single-use and rotate.** A successful
   `grant_type=refresh_token` call returns a **new** `access_token` *and a new
   `refresh_token`*, and **invalidates the old refresh token.** You must persist
   the new pair atomically; replaying the old refresh token fails.

2. **Rotating the refresh token also invalidates the sibling access token.** Once
   a refresh token has been consumed, the access token it previously produced can
   be rejected with `401 Invalid authentication credentials` **even though its
   `expiresAt` is still in the future.** Do not treat a future `expiresAt` as
   proof a token is live.

3. **A refresh-token-less credential set is a dead end.** Because of (1), if a
   row/file ends up with an `accessToken` but **no `refreshToken`**, it is
   *unrecoverable* the moment that access token expires or is invalidated — there
   is nothing to refresh with. This is why Zimmer refuses to persist incomplete
   credentials anywhere (`ClaudeAccount.complete_claude_oauth?`).

4. **The Claude CLI refreshes tokens on its own, mid-session.** While a session
   runs, the CLI may refresh and **write a new pair into the shared
   `~/.claude/.credentials.json`** without telling Zimmer. Zimmer must capture those
   CLI-rotated tokens back into the DB (`sync_tokens_from_filesystem!`) or its DB
   copy goes stale and the next Zimmer-driven refresh fails with `invalid_grant`.

### Observed failure responses

| Condition | HTTP | Body |
|-----------|------|------|
| Dead/replayed refresh token | `400` | `{"error":"invalid_grant","error_description":"Refresh token not found or invalid"}` |
| Revoked/!live access token (CLI call) | `401` | `Failed to authenticate. API Error: 401 Invalid authentication credentials` |
| Permanent OAuth failures we treat as `needs_reauth` | `401`/`404`, or `400` with `invalid_grant`/`invalid_client`/`unauthorized_client`, or Anthropic `{"error":{"type":"invalid_request_error"|"authentication_error"}}` | — |

### Token lifetime

`expires_in` observed at **~8 hours** (e.g. minted 23:13Z → `expiresAt` 07:08Z
next day). Zimmer refreshes anything within `REFRESH_THRESHOLD` (15 min) of expiry on
a 5-minute cron (`RefreshRuntimeAuthTokensJob`).

---

## 4. Known CLI quirks we actively defend against

- **The CLI sometimes rewrites `~/.claude/.credentials.json` without the
  `claudeAiOauth` tokens** (it uses this file for MCP OAuth state too). If Zimmer
  blindly adopted that, it would erase the refresh token from the DB and brick the
  pool. Guarded by `complete_claude_oauth?` on every read *and* write path.

- **`~/.claude.json` carries unrelated state** (project history, MCP config). We
  deliberately do **not** share it across containers or treat it as the source of
  truth for "current account" — the DB is. We only read its `oauthAccount` field,
  and only as a fallback identity signal.

- **Refresh writes credentials but not identity.** `refresh_token!` →
  `write_credentials_to_filesystem!` updates `.credentials.json` only, never
  `.claude.json`. That is fine (identity is unchanged by a refresh) but means you
  cannot assume the two files were written together.

---

## 5. The login command (interactive re-auth)

The supported re-auth path is the UI-driven login on the `/quotas` screen
(`RuntimeLoginJob` + `ClaudeLoginDriver`), which spawns the CLI under a PTY in an
**isolated `CLAUDE_CONFIG_DIR` scratch dir** so an in-progress login never touches
live credentials, then captures the result into the DB.

- **Command:** `claude auth login --claudeai`
- **Env isolation:** `CLAUDE_CONFIG_DIR=<scratch dir>`
- **Flow:** the CLI prints an authorize URL, then blocks on a `Paste code here`
  prompt. The user authorizes in a browser and pastes back a `<code>#<state>`
  string, which Zimmer writes to the held-open CLI's stdin.
- **Capture guard:** `ClaudeLoginDriver#capture!` rejects the login if the
  authenticated email ≠ the target account, or if the credentials are missing
  `accessToken`/`refreshToken`.

> If `claude auth login --claudeai`, the authorize-URL host, or the `Paste code
> here` prompt text changes, the login flow breaks. Those strings live in
> `ClaudeLoginDriver` (`URL_REGEX`, `PASTE_PROMPT`, `command`).

### Driving a login by hand (break-glass)

If the UI is unavailable, the same job can be driven from a console (this is how
the 2026-06-11 outage was recovered):

```ruby
acct = ClaudeAccount.find_by!(email: "bob@tadasant.com")
attempt = acct.runtime_login_attempts.create!(runtime: "claude_code")
RuntimeLoginJob.perform_later(attempt.id)
# poll attempt.verification_url (uncached), hand the URL to a human,
# then: attempt.update!(pasted_code: "<code>#<state>") and poll for status=succeeded
# finally: AccountRotationService.new.activate!(acct, snapshot_trigger: "manual_recovery")
```

---

## 6. Usage-limit messages — the strings that trigger account rotation

Rotation between accounts in the pool is triggered by a **usage-limit error
string** the CLI records in the transcript, not by an HTTP status. When an account
hits its usage cap, the CLI writes a synthetic transcript entry with
`isApiErrorMessage: true` and (currently) `"error": "rate_limit"`, whose message
text names the limit and its reset time. `ApiErrorRetryService` must recognize
that text as a **usage limit** (→ `:quota_exceeded` → rotate to the next account),
and distinguish it from a **transient burst rate limit** (→ retry the *same*
account with backoff). The discriminator is `ACCOUNT_QUOTA_LIMIT_PATTERN`.

> ⚠️ **This message wording is a moving target, and getting it wrong is silent.**
> If a usage-limit string stops matching the pattern, it falls through to the
> transient-rate-limit path: the session retries the already-capped account 6×
> and fails with `api_error_retries_exhausted` **without ever rotating** — even
> though the pool is full of healthy accounts. There is no error log that says
> "rotation should have fired"; the only signal is failed sessions plus an
> `AccountRotationEvent` table containing only `source=manual` rows.

### Known usage-limit message formats

The reset time appears as a bare time (`5pm`, `5:50pm`), or month+day+time
(`Jan 15, 6pm`). A descriptor word may sit between "your" and "limit":

```
You've hit your limit · resets 5pm (UTC)              # legacy (overall)
You've hit your limit · resets Jan 15, 6pm (UTC)      # legacy (overall, dated reset)
You've hit your session limit · resets 5:50pm (UTC)   # 5-hour session window
You've hit your weekly limit · resets Jan 15, 6pm (UTC)
```

The pattern is anchored on `hit your … limit … resets` (with the descriptor word
optional) rather than the literal `hit your limit`, so a new descriptor word does
not break detection. The explicit **`resets <time>`** clause is what separates a
usage cap from a transient `Rate limit reached` / `429 Too Many Requests` burst,
which never carries a reset time. **If the CLI ever drops the `resets` clause or
changes the verb, update `ACCOUNT_QUOTA_LIMIT_PATTERN` and the format list above
in the same PR** (canonical pattern + tests:
`app/services/api_error_retry_service.rb`,
`test/services/api_error_retry_service_test.rb`).

> Note the `"error"` field on these entries is `"rate_limit"` (no `_error`
> suffix), which is **not** in `RATE_LIMIT_ERROR_TYPES` (`rate_limit_error`). It
> only matches because the field value `rate_limit` matches the
> `/rate.limit/i` *message* pattern. Don't rely on the error-type enum here; the
> message text is the source of truth for the usage-cap vs transient split.

---

## 7. Worked examples

Concrete instances of these assumptions being violated, kept as regression
narratives.

### 7a. The 2026-06-14 "no auto-rotation on usage limit" failure

**Symptom:** sessions hit the account usage limit and failed en masse with
`api_error_retries_exhausted` instead of rotating to another account. The pool was
healthy (3 accounts, all `active`, valid access+refresh tokens) and every
`AccountRotationEvent` was `source=manual` — auto-rotation had **never** fired.

**State found:** failed sessions' transcripts all carried
`error="rate_limit"`, text `You've hit your session limit · resets 5:50pm (UTC)`.

**Root cause:** the CLI had changed its usage-limit wording from
`hit your limit` to `hit your session limit`. `ACCOUNT_QUOTA_LIMIT_PATTERN` was
`/hit your limit.*resets/i`, which the new string does not match (assumption in
§6 violated). The error was therefore classified as a transient rate limit,
retried 6× against the already-capped account, and failed without rotating.

**Fix:** broaden the pattern to `/hit your\b.*\blimit\b.*\bresets\b/i` (descriptor
word optional) and record the "session"/"weekly" variants as known formats (§6).

### 7b. The 2026-06-11 "Failed to authenticate" outage

A concrete instance of these assumptions being violated, kept as a regression
narrative.

**Symptom:** every session failed with `401 Invalid authentication credentials`.
A `/quotas` re-login "succeeded" but did not unstick it.

**State found:**
- DB `bob`: `accessToken=A`, `refreshToken=R_old`, current.
- DB `tadas412`: `accessToken=A` (same as bob), **no refresh token**.
- Shared `.credentials.json`: `accessToken=A`, **no refresh token**.
- `~/.claude.json`: **web container said `tadas412`, worker said `bob`** — the
  per-container identity split, live.

**Root cause (two compounding defects):**
1. **Cross-container contamination.** A token-sync path validated the *shared*
   credentials against the *container-local* `~/.claude.json`. Running on the
   container whose identity didn't match the shared file's true owner, it grafted
   one account's access token onto the other account's DB row.
2. **No completeness guard on bootstrap/outbound writes.** `sync_from_filesystem!`
   and the disk writers happily persisted a refresh-token-less credential set
   (assumption #3 violated), so once the surviving refresh token (`R_old`) was
   consumed and invalidated (assumption #1/#2), **no valid refresh token existed
   anywhere** → unrecoverable without a fresh login.

**Fix:** the shared **owner marker** (so identity travels with the shared
credentials) + the **completeness invariant** on every persist path. See the
architecture doc and the PR that accompanies this file.
