# X (Twitter) OAuth Token Vending

Zimmer-side infrastructure that lets an **x-twitter MCP server** run reliably
across sessions, despite X's single-use rotating refresh tokens.

## The problem this solves

X OAuth 2.0 **rotates refresh tokens single-use**: the first `grant_type=refresh_token`
exchange returns a brand-new refresh token and invalidates the old one (they also
expire ~6 months). A typical x-twitter server's built-in refresh-token provider
holds the rotated token **in memory only**. Zimmer launches `npx x-twitter-mcp-server`
fresh per session, so a static refresh-token seed in `mcp_secrets` would work for at
most **one** session's first tool call, then every later session would fail auth.

The fix: run the server in its **static access-token mode** (`X_OAUTH_ACCESS_TOKEN`),
backed by a durable Zimmer-side refresher that owns the rotating refresh token and
persists every rotation. This mirrors Zimmer's own `McpOauthCredential` /
`RefreshMcpOauthTokensJob` precedent for rotating OAuth credentials.

## Pieces

| Piece | File | Role |
|-------|------|------|
| Durable store | `app/models/x_oauth_credential.rb` + `db/migrate/20260706010000_create_x_oauth_credentials.rb` | One row per authorized X account. Holds the rotating access/refresh tokens, expiry, scopes. |
| Refresher (on-demand) | `XOauthCredential#current_access_token` | Row-locked refresh-if-expiring; used at session-prep so the injected token is always fresh. |
| Refresher (cron) | `app/jobs/refresh_x_oauth_tokens_job.rb` (every 15 min) | Proactively refreshes ahead of expiry, keeps the rotating chain alive. |
| Token vendor | `app/services/x_oauth_token_vendor.rb` | Resolves an `X_OAUTH_ACCESS_TOKEN*` var to a fresh token. |
| Injection hook | `app/services/secrets_interpolator.rb` (`get_env_value`) | Consulted first, ahead of static credentials/ENV, so `${X_OAUTH_ACCESS_TOKEN}` in a catalog server's `env` resolves to the freshest minted token at session launch. |
| Bootstrap | `app/services/x_oauth_bootstrap.rb` + `lib/tasks/x_oauth.rake` | One-time human-consent mint of the durable refresh token. |

### Auth split

- **Static client creds** (`X_OAUTH_CLIENT_ID` / `X_OAUTH_CLIENT_SECRET`) live in
  Rails credentials `mcp_secrets:` (read via `XOauthCredential.client_id/.client_secret`,
  with an `ENV` fallback). This is the confidential client; refresh uses **HTTP
  Basic auth** at `https://api.x.com/2/oauth2/token`, per X's confidential-client
  requirement.
- **Rotating tokens** live on the `x_oauth_credentials` row — the only
  runtime-writable part.

## Session-prep injection flow

1. AIR `prepare` writes `.mcp.json`; its `air-secrets-env` first pass leaves the
   unresolved `${X_OAUTH_ACCESS_TOKEN}` literal (it is not in `process.env`).
2. Zimmer's `ClaudeMcpConfigPostProcessor` → `SecretsInterpolator#resolve_entry!`
   runs the authoritative second pass. For `X_OAUTH_ACCESS_TOKEN` it calls
   `XOauthTokenVendor.resolve`, which returns `XOauthCredential#current_access_token`
   (refreshing under a row lock if the token is expiring).
3. The x-twitter server launches in static access-token mode with a valid token.

## One-time bootstrap (human consent required)

X has no non-interactive user-context grant. Zimmer is headless, so this is a
copy-the-code flow (the loopback callback a server's `oauth-setup` uses cannot
reach a remote worker):

```bash
# Client creds must be in mcp_secrets (or ENV). Then:
bin/rails x_oauth:authorize
#   → prints a consent URL. Open it, authorize, and copy the `code` param from
#     the (dead) redirect URL bar. The redirect URI (default
#     http://localhost:8080/callback) must be registered on your X app.
CODE=<pasted-code> bin/rails x_oauth:complete
#   → exchanges the code (Basic auth), stores the credential.
bin/rails x_oauth:status   # inspect (no secrets printed)
```

Scopes minted: `tweet.read users.read bookmark.read bookmark.write offline.access`
(`bookmark.write` is required for the read-write tier; it grants access only to
private bookmarks — no public-mutation scope is ever requested).

## Deploy prerequisites

1. Register an X (Twitter) OAuth 2.0 **confidential client** app and add its
   `X_OAUTH_CLIENT_ID` and `X_OAUTH_CLIENT_SECRET` to `mcp_secrets` in each
   environment's Rails credentials. Register the bootstrap redirect URI
   (default `http://localhost:8080/callback`, overridable via `REDIRECT_URI`) on
   that app.
2. Run the bootstrap above once in the target environment to seed the durable
   refresh token (`bookmark.write`-scoped).

## Catalog registration (lives in `tadasant/zimmer-catalog`, not this repo)

Registering the server into Zimmer's catalog is a separate step in the catalog
repo (`tadasant/zimmer-catalog` → `catalog/mcp.json`). Add these two tiered
entries. Both tiers inject the **same** `${X_OAUTH_ACCESS_TOKEN}` (same authorized
account); the tier difference is only which tool groups are exposed:

> ### ⛔ BLOCKER — verify the npm package before registering
>
> As of the upstream provenance for this feature (pulsemcp/pulsemcp#4657), the npm
> name **`x-twitter-mcp-server` was squatted by a DIFFERENT, third-party package**
> exposing public-mutation tools (`x_create_tweet`, `x_like`, `x_follow`,
> `x_delete_tweet`, …). Registering that command verbatim would hand sessions
> post/like/follow/delete powers — the opposite of the read-only + private-bookmark
> guarantee. **Before registering:** confirm `command`/`args` point at a server you
> trust that exposes only the intended tool groups. The `args` below use
> `x-twitter-mcp-server@latest` as a **placeholder** — swap it for the real,
> verified published name.

```jsonc
"x-twitter-readonly": {
  "title": "X / Twitter — Read-Only",
  "description": "X (Twitter) MCP server, read-only: home timeline, a user's tweets, bookmarks, recent search, tweet/user lookup. No write tools. OAuth2 user-context; Zimmer injects a fresh access token as X_OAUTH_ACCESS_TOKEN (XOauthCredential / XOauthTokenVendor).",
  "type": "stdio",
  "command": "npx",
  "args": ["-y", "x-twitter-mcp-server@latest"],
  "env": {
    "X_OAUTH_ACCESS_TOKEN": "${X_OAUTH_ACCESS_TOKEN}",
    "X_TWITTER_ENABLED_TOOLGROUPS": "readonly"
  }
},
"x-twitter-readwrite": {
  "title": "X / Twitter — Read-Write (private bookmarks)",
  "description": "X (Twitter) MCP server, reads plus PRIVATE bookmark add/remove (create_bookmark/remove_bookmark). No public-mutation tools exist. OAuth2 user-context; Zimmer injects a fresh access token as X_OAUTH_ACCESS_TOKEN.",
  "type": "stdio",
  "command": "npx",
  "args": ["-y", "x-twitter-mcp-server@latest"],
  "env": {
    "X_OAUTH_ACCESS_TOKEN": "${X_OAUTH_ACCESS_TOKEN}",
    "X_TWITTER_ENABLED_TOOLGROUPS": "readonly,readwrite"
  }
}
```

Notes for the follow-on:
- The x-twitter server reads only `X_OAUTH_ACCESS_TOKEN` +
  `X_TWITTER_ENABLED_TOOLGROUPS` (see its README).
- `X_OAUTH_ACCESS_TOKEN` is NOT a static `mcp_secrets` value — it is vended
  dynamically by Zimmer at session-prep. Do not add it to `mcp_secrets`.
