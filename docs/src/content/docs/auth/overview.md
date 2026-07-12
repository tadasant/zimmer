---
title: Auth architecture
description: The four independent auth systems in Zimmer, what protects what, and the honest answer to "who can do what."
sidebar:
  order: 1
---

Zimmer has four separate authentication systems that share almost nothing. Understanding which is
which is most of the battle.

```mermaid
flowchart TB
    subgraph none["1 · Human → Zimmer: NOTHING"]
        W["Web UI · /supervisor admin<br/>/quotas · /settings · /jobs<br/>NO AUTH OF ANY KIND"]
    end
    subgraph api["2 · Client → REST API"]
        A["X-API-Key header<br/>vs ENV['API_KEYS'] (comma-separated)<br/>opaque, unscoped, no identity"]
    end
    subgraph harness["3 · Zimmer → Agent vendor"]
        H["ClaudeAccount pool (both runtimes)<br/>OAuth refresh + rotation on quota<br/>tokens on disk AND in Postgres"]
    end
    subgraph mcp["4 · Agent → MCP servers"]
        M["McpOauthCredential<br/>PKCE + DCR + RFC 8414 discovery<br/>injected into the CLI's credential file"]
    end

    U["You"] --> W
    C["Script / MCP self-session"] --> A
    W --> H
    H --> V["Anthropic · OpenAI"]
    M --> S["Linear · Slack · Google · …"]
```

## 1. Human → Zimmer: there is no authentication

This is not a simplification. `ApplicationController` has no `before_action` for auth, no session
auth, no Devise, no OmniAuth, no HTTP Basic. There are no login routes. There is no `User` model in
the auth path.

Everything is open to anyone who can reach the host:

- the session dashboard and every transcript,
- `/settings`, `/quotas` (including the OAuth login flow),
- the GoodJob dashboard at `/jobs`,
- and `/supervisor` — the Administrate admin panel, which exposes `claude_accounts` (whose
  `oauth_config` JSONB holds plaintext access and refresh tokens), `mcp_oauth_credentials`,
  `x_oauth_credentials`, and `runtime_login_attempts` as *editable* resources.

`app/controllers/supervisor/application_controller.rb` is the whole story:

```ruby
before_action :authenticate_supervisor

def authenticate_supervisor
  # TODO Add authentication logic here.
end
```

:::danger[The security model is "put it on a tailnet"]
That is deliberate: the network perimeter is the authentication boundary, and Zimmer's own Terraform
enforces it. The DigitalOcean firewall allows only `22/tcp` and Tailscale's `41641/udp`, port 80 is
closed at the edge, and the app is reachable only over the tailnet, at `http://zimmer`.

The sharp edge is real. The entire security posture rests on that perimeter, so any deployment that
exposes port 80 (a reverse proxy, a public load balancer, a well-meaning `docker run -p 80:80` on a
box with a public IP) hands an anonymous visitor your Anthropic refresh tokens.
Tracked in [#42](https://github.com/tadasant/zimmer/issues/42) and
[#43](https://github.com/tadasant/zimmer/issues/43).

There are also at least six `# TODO: Add proper authorization checks` comments scattered through
`sessions_controller.rb`.
Tracked in [#44](https://github.com/tadasant/zimmer/issues/44).
:::

## 2. Client → REST API: `X-API-Key`

The only authenticated surface. `Api::BaseController#authenticate_api_key` compares the `X-API-Key`
header against `ENV["API_KEYS"]` (comma-separated) using a constant-time comparison.

What it isn't:

- **No scoping.** Keys are opaque strings with no identity, no permissions, no ownership. Any valid
  key can read, mutate, and delete every session, trigger, and category.
- **No rotation without a restart** — the valid-key list is memoized per request instance from ENV.
- **No audit trail** of which key did what.

Three endpoints skip it entirely:

- `POST /api/v1/elicitations` and `GET /api/v1/elicitations/:id` — required by the MCP
  fallback-elicitation protocol, since the MCP child process has no key.
- `GET /api/secrets/keys` — because `Api::SecretsController` inherits `ApplicationController`, not
  `Api::BaseController`. It leaks secret names and descriptions (not values), unauthenticated.

## 3. Zimmer → the agent vendor

A pool of accounts (`ClaudeAccount` — misleadingly named; it serves both runtimes, discriminated
by a `runtime` column) with automatic OAuth refresh and automatic rotation when one hits its quota.

→ [Agent harness credentials](/auth/harness/)

## 4. The agent → MCP servers

A completely separate system: `McpOauthCredential` + `McpOauthPendingFlow`, doing full RFC 8414
discovery, RFC 7591 dynamic client registration, and PKCE — then writing the resulting tokens into
the CLI's own credential file so the agent's MCP client picks them up.

→ [MCP server OAuth](/auth/mcp-oauth/)

## Prefer remote MCP servers to long-lived API tokens

When you give an agent a new capability, you usually have two ways to do it:

- a **stdio MCP server or a CLI** — a local process that reads a long-lived API token out of the
  environment (`env: { "LINEAR_API_KEY": "${LINEAR_API_KEY}" }`), or a CLI you `op`-inject a token
  into and then shell out to;
- a **remote MCP server** — an `http` / `streamable-http` / `sse` endpoint that Zimmer authorizes
  once over OAuth, with dynamic client registration, PKCE, and a refresh token it rotates for you.

**Reach for the remote server.** The difference shows up on the bad day, not the good one. Agents
read and write an enormous amount of text — logs, transcripts, diffs, error messages they paste back
to themselves — and a credential that lives in the environment will eventually land in one of them.
If that credential is a long-lived API token, your options are to accept a permanent exposure or to
spend the next five hours hunting down and rotating every copy of it. If it is a short-lived OAuth
token that Zimmer already rotates on a schedule, it expires on its own, and revoking it is one click
plus a browser re-auth.

The same asymmetry is why the harness itself signs in rather than taking an API key: see
[agent harness credentials](/auth/harness/).

[**Strad**](https://strad.tadasant.com) is the remote-MCP platform built to pair with Zimmer — the
place to put the servers you'd otherwise be running as token-hungry local processes. Its docs are
going up now.

:::caution[Zimmer does not fully live by this yet]
The advice is real, and so is the gap. Zimmer's own `mcp.json` still carries stdio servers whose
`env` holds `${VAR}` placeholders, and `SecretsLoader.all` — the union of *every* secret in
`mcp_secrets` — is written to a `.env` file in **every session clone** and merged into the agent's
environment, regardless of which servers that session actually selected. A 1Password service-account
token is exactly the kind of long-lived credential this section tells you to avoid, and it is one of
the values in that file.

Every stdio server you replace with a remote one shrinks that blast radius. See
[MCP servers](/air/mcp-servers/#secrets-never-touch-the-catalog) for how the placeholder-and-secret
plumbing works today.
:::

## Nothing is encrypted at rest

:::danger[No `encrypts` declaration exists anywhere in the codebase]
There is no `encrypts` in any model and no `config.active_record.encryption.*` anywhere in `config/`.

In `db/schema.rb`:

- `mcp_oauth_credentials.access_token`, `.refresh_token`, `.client_secret` — plain `text` / `string`
- `mcp_oauth_pending_flows.code_verifier`, `.client_secret` — unencrypted
- `claude_accounts.oauth_config` — plain `jsonb`, holding Anthropic and OpenAI access and refresh
  tokens
- `x_oauth_credentials` — plain
- `runtime_login_attempts.pasted_code` — plain `string`

`XOauthCredential`'s own header admits it: *"access_token / refresh_token are stored as plain text…
Security relies on database access controls."*

Combined with an unauthenticated Administrate panel that renders those columns, database access
controls are the only control, and the admin panel bypasses them.
:::

## The environment variables that matter

| Var | Used for |
| --- | --- |
| `API_KEYS` | REST API auth (comma-separated) |
| `APP_HOST` | The MCP OAuth **redirect URI**. Defaults to `localhost:3000`, and picks `http` iff the host string contains "localhost". |
| `RAILS_MASTER_KEY` | Unlocks Rails credentials (`mcp_oauth_clients`, `mcp_secrets`) |
| `X_OAUTH_CLIENT_ID` / `_SECRET` | X/Twitter token vending |
| `ANTHROPIC_API_KEY` | Local dev, when not using OAuth |

:::caution[`APP_HOST` unset breaks every MCP OAuth flow]
`McpOauthService` does `ENV.fetch("APP_HOST") { "localhost:3000" }`. It is not set in the shipped
cloud-init, so on a stock deploy every OAuth callback URL points at `localhost:3000` and every flow
fails.
:::
