---
title: Connecting to /mcp over OAuth
description: Zimmer is its own OAuth 2.1 authorization server for /mcp, so a Claude.ai custom connector or any other remote MCP client connects with no API key.
sidebar:
  order: 4
---

Zimmer's MCP endpoint, `POST /mcp`, takes two credentials. One is the API key that every agent
session and script already uses (see [Auth architecture](/auth/overview/#2-client--rest-api-x-api-key)).
The other is an OAuth access token that Zimmer issues itself. With it, a standard remote MCP client
connects from nothing but the URL: Claude.ai's custom connectors, the MCP Inspector, VS Code. You
paste `https://<your-zimmer>/mcp`, approve the connection in a browser, and the client stays
connected.

This is the opposite direction from [MCP server OAuth](/auth/mcp-oauth/). There, Zimmer is the
*client* of somebody else's MCP server. Here, Zimmer is the *server*. The code is kept apart to
match: `OauthServer::*` and the `oauth_server_*` tables here, `McpOauth*` there.

## The flow

```mermaid
sequenceDiagram
    participant C as MCP client (Claude.ai)
    participant Z as Zimmer
    participant H as You, in a browser
    C->>Z: POST /mcp (no token)
    Z-->>C: 401 WWW-Authenticate: Bearer resource_metadata=".../.well-known/oauth-protected-resource/mcp"
    C->>Z: GET /.well-known/oauth-protected-resource/mcp
    C->>Z: GET /.well-known/oauth-authorization-server
    alt Dynamic Client Registration
        C->>Z: POST /oauth/register
    else Client ID Metadata Document
        Note over C,Z: client_id is an https URL; Zimmer fetches it at /oauth/authorize
    end
    C->>H: open /oauth/authorize?client_id&redirect_uri&code_challenge(S256)&state&resource
    H->>Z: GET /oauth/authorize (signed in to the web UI)
    Z-->>H: consent screen
    H->>Z: POST /oauth/authorize (Approve)
    Z-->>H: 302 redirect_uri?code&state&iss
    H->>C: code
    C->>Z: POST /oauth/token (authorization_code + code_verifier)
    Z-->>C: access_token (1 h) + refresh_token (180 d)
    C->>Z: POST /mcp, Authorization: Bearer access_token
    C->>Z: POST /oauth/token (refresh_token) — rotated each time
```

| Endpoint | What it is |
| --- | --- |
| `GET /.well-known/oauth-protected-resource/mcp` (also without `/mcp`) | RFC 9728 metadata: the resource is `<issuer>/mcp`, and its authorization server is `<issuer>` |
| `GET /.well-known/oauth-authorization-server` (also with `/mcp`) | RFC 8414 metadata. Advertises `registration_endpoint`, `client_id_metadata_document_supported: true`, `code_challenge_methods_supported: ["S256"]`, `token_endpoint_auth_methods_supported: ["none"]` |
| `POST /oauth/register` | Dynamic Client Registration (RFC 7591), open |
| `GET`, `POST /oauth/authorize` | The consent screen, and your decision |
| `POST /oauth/token` | `authorization_code` and `refresh_token` grants |
| `POST /oauth/revoke` | RFC 7009. Always 200 |

Everything except `/oauth/authorize` is a machine endpoint: JSON or form-encoded, open CORS (`*`,
no credentials), and outside the web UI's CSRF check and sign-in. `/oauth/authorize` is a web page
and has both.

## What a token opens

**Exactly what an `api` key opens on `/mcp`, and nothing outside it.** Every tool group is
reachable, and `?tool_groups=` and `allowed_agent_roots=` on the URL narrow the connection the same
way they do for a key. A token does not open the REST API (`/api/v1/*`) or a Zimmer plugin's
`/mcp/external_app`. Both refuse it the way they refuse any unknown key. The one exception is a
token issued to [Zimmer's own iOS app](#the-built-in-ios-app-client), which also opens the REST
endpoints that app drives.

The reasoning: the person who approves a connection is someone the deployment already trusts with
the whole web UI. Zimmer is [one circle of trust](/intro/philosophy/), and inside it an `api` key
already reaches every tool. Issuing a narrower token would mean inventing a permission system that
the key, the web UI and the agents' shells don't have. Keeping it to `/mcp` is a narrowing that
costs nothing: an MCP client only speaks MCP.

A token changes what a tool *defaults to* in one place: `quick_router` starts an OAuth caller's
router as priority, because a person is waiting on that client. See
[`quick_router`](/extend/mcp-server/#quick_router-the-door-for-clients-that-do-not-know-zimmer).

## Relay only, or acts on my behalf

Every connection has one of two levels, and the person approving it picks one on the consent
screen. Neither is selected for them (not even when the authorization URL asks for one), and
approving without picking one issues no code.

| Level | Scope the grant holds | What a message it sends is recorded as |
| --- | --- | --- |
| **Relay only** | `mcp` | the assistant's. Nothing lands in the session's [human messages](/sessions/hierarchy-and-human-messages/), so a merge gate does not read it as the person's approval |
| **Acts on my behalf** | `mcp zimmer:act-as-human` | the person who approved the connection, on the `assistant` channel, naming the grant and the client |

The level changes what a message *means*, not what the connection can reach: both levels open the
same tools. It is for an assistant the person talks to directly, such as the Claude app by voice,
where their decision ("merge 407") reaches Zimmer as a `follow_up` the assistant writes. With
**acts on my behalf**, that follow-up is the person's own message. See
[what is captured](/sessions/hierarchy-and-human-messages/#what-is-captured-and-what-is-not) for the
exact calls.

The choice is the person's, not the client's. A `scope` on the authorization request is ignored, as
[RFC 6749 §3.3](https://www.rfc-editor.org/rfc/rfc6749#section-3.3) allows. The token response's
`scope` reports what the grant holds: `mcp`, or `mcp zimmer:act-as-human`. Both scopes are in
`scopes_supported` in the discovery documents. The level is read from the grant on every request,
so changing it on the settings page applies from the connection's next call without a new token.

The trust this buys is the person's choice, not something Zimmer checks about the words. An
assistant's model writes the arguments of every call, so whatever steers that model can write a
message that is then recorded as the person's. See
[Limitations](/limitations/#connecting-to-mcp-over-oauth).

## Who can approve

`/oauth/authorize` names the person who approved, and issues a code only when both of these hold.
They are checked **before anything else on the request**. Until both hold, Zimmer fetches no client
document and redirects no error to the client, so a URI anyone may register cannot turn Zimmer into
an open redirector.

1. **Someone is signed in to the web UI.** `/oauth/authorize` is a browser page on
   `ApplicationController`, so it sits behind [web sign-in](/auth/web-sign-in/): Google, then the
   second factor. A signed-out browser is sent to `/login` and, once signed in, back to the exact
   `/oauth/authorize?…` URL it asked for, with every query parameter intact (`client_id`,
   `redirect_uri`, `state`, `code_challenge`, `code_challenge_method`, `resource`, `scope`). The
   signed-in identity's email is the one the connection is issued to. With web sign-in off, nobody
   is signed in, and `/oauth/authorize` answers *"Sign in to Zimmer first"* and issues nothing.
2. **Their email is in an allowed domain.** That is `OAUTH_SERVER_ALLOWED_DOMAINS` (comma-separated),
   or, when that is unset, web sign-in's own `ZIMMER_WEB_AUTH_ALLOWED_DOMAINS`. If neither is set,
   nothing is issued. The check runs at consent, again when the code is exchanged, and on
   every refresh. Taking a domain off the list stops that domain's refreshes and revokes those
   connections.

In development and test with web sign-in off, `ZIMMER_DEV_WEB_USER_EMAIL` names the signed-in
person, so the flow can be walked end to end on a laptop. No other environment reads it, and with
web sign-in on it is ignored.

The return trip rides web sign-in's own `return_to`, which keeps a URL of up to 2,000 characters.
A real authorization request is a few hundred.

## Registering a client

**Public clients only.** Every client proves itself with PKCE, never with a secret, so Zimmer stores
no client secrets. `token_endpoint_auth_method` must be absent or `none`.

**Redirect URIs** must be `https`, or `http` on a loopback host (`localhost`, `127.0.0.1`, `[::1]`)
for a program on your own computer. Custom schemes, fragments and userinfo are refused. The
`redirect_uri` on an authorization request must exactly match one the client registered (or that its
document lists).

**Extra grant types are narrowed, not refused.** Claude.ai lists the JWT-bearer grant and VS Code the
device-code grant. Zimmer requires only that `authorization_code` (and response type `code`) be in
the list, and registers the client for `authorization_code` and `refresh_token`.

### The built-in iOS app client

[Zimmer's iOS app](/extend/ios-app/) does not register. Its client is built in under the fixed
`client_id` **`zimmer-ios`** (`OauthServer::NativeApp`), and the `oauth_server_clients` row is
created the first time an authorization request names it. Its `registration_type` is `first_party`,
which the pruner below never deletes.

- **Its redirect URI is a private-use scheme**, `com.tadasant.zimmer:/oauth/callback` — the reverse
  of the app's bundle id (RFC 8252 §7.1). Registered clients still may not use custom schemes,
  because any app on a phone can claim one. This one URI is fixed in Zimmer's code rather than claimed by
  a caller, and the code it carries is worthless without the PKCE verifier that never left the app
  that started the flow (RFC 8252 §8.1). Any other `redirect_uri` with this `client_id` gets an
  error page, never a redirect.
- **The consent screen says so.** It names "Zimmer for iOS — Zimmer's own app, built in" and shows
  the scheme it returns to.
- **Its tokens also open the REST API**, on the controllers that declare
  `accepts_native_app_tokens` (sessions and the Quick Router, today). A token from any other client is still refused
  there. Like every token this server issues, it opens all of `/mcp` too, and the consent screen
  says so. See [the REST API](/extend/rest-api/#the-ios-apps-bearer-token).

### Dynamic Client Registration

`POST /oauth/register` takes the RFC 7591 JSON body and answers `201` with a `client_id` that
starts with `zmc_`. Registration is open, with no initial access token: the connector dialog you paste
the URL into has nowhere to put one. Registering grants nothing on its own. A registration that never
gets a consent is pruned after seven days, and so is a cached document whose cache ran out seven
days ago and that never got a consent either.

### Client ID Metadata Documents

A client can skip registration by using an HTTPS URL as its `client_id`. The JSON document at that
URL describes the client. Claude.ai's is `https://claude.ai/oauth/mcp-oauth-client-metadata`.
Zimmer fetches the document at `/oauth/authorize`, checks it, and caches it on an
`oauth_server_clients` row.

Fetching a URL a stranger chose is how SSRF happens, so the fetch is held tight. Nothing is fetched
until a signed-in person from an allowed domain has opened the authorization request. The fetch
itself:

- The URL must be `https`, already in normal form (lowercase host, no `:443`), with a path, and with
  no userinfo, fragment or `.`/`..` segments.
- Every address the host resolves to must be public. The denied ranges are RFC 6890's private,
  loopback, link-local, CGNAT, documentation, benchmarking and multicast ranges for IPv4, and anything
  outside `2000::/3` for IPv6. IPv4-mapped IPv6 addresses are checked as the IPv4 address they map to.
  The connection then dials the address that was checked, so a second DNS answer cannot rebind it.
- Redirects are not followed. The whole exchange (DNS, connect, TLS and body) must finish within 5
  seconds, the body is capped at 5 KiB, and the response must be JSON. An `http_proxy` in the
  environment is ignored, so a proxy cannot resolve the name a second time.
- The document's `client_id` must equal the URL exactly. It must list `redirect_uris`, and it must not
  carry a `client_secret`.
- Nothing the document points at (`logo_uri`, `jwks_uri`, `client_uri`) is ever fetched.

A valid document is cached for its `Cache-Control: max-age`, at most an hour, or five minutes if it
says nothing. `no-store` means it is not cached. A failed fetch is never cached. The token endpoint
does not fetch the document again, because the code or refresh token is already bound to the
client's row.

The consent screen names the host that published a CIMD client's document. A self-registered
client's name is shown as its own claim. A loopback redirect gets a warning: any program on your
computer can claim to be any client that way.

## Tokens

| | Lifetime | Configured by |
| --- | --- | --- |
| Authorization code | 60 s, single use | — |
| Access token (`zmr_oat_…`) | 1 hour | `OAUTH_SERVER_ACCESS_TOKEN_TTL_SECONDS` (300 to 86,400) |
| Refresh token (`zmr_ort_…`) | 180 days, renewed on every refresh | `OAUTH_SERVER_REFRESH_TOKEN_TTL_SECONDS` (3,600 to 34,560,000) |

Access tokens are short and refresh tokens are long, so a connector that is used at least every six
months never asks you to sign in again. Every value is opaque and random. Zimmer stores only its
SHA-256 digest, and the plaintext exists only in the response that issued it.

**Refresh tokens rotate.** Each refresh spends the presented refresh token and returns a new pair. If
a spent refresh token is presented again more than 60 seconds after it was spent, the whole
connection is revoked (RFC 9700 §4.14.2). Within those 60 seconds it is only refused. That window is
for a client that refreshes twice at once with the same token: one call wins, and the other must not
end a connection that the winner's new tokens are still using. It does not rescue a client that lost
the response to its own refresh. That client is refused and has to be approved again.

**Tokens are bound to the resource.** Every access token's audience is `<issuer>/mcp`, whether or not
the client sent a `resource` (RFC 8707). A `resource` that names anything else is `invalid_target`.
The comparison ignores the query string, the fragment and one trailing slash, because the URL you
paste may carry `?tool_groups=`. `/mcp` refuses a token whose audience is not its own resource.

**The issuer** is `OAUTH_SERVER_ISSUER` when set, otherwise the instance's base URL
(`ZIMMER_PROD_BASE_URL` in production, `ZIMMER_STAGING_BASE_URL` on staging), the same URL the web
sign-in builds its callback from. It must be a bare origin, and it is what every metadata URL, the
`resource`, the audience and the `iss` on the authorization response are built from, so it must be the
origin the client reaches Zimmer at. `resource` is always exactly `<issuer>/mcp`. **It never comes
from the request**, in any environment: the `Host` header is whatever the client or the edge in front
of Rails made it, so a forged one cannot move the metadata. A production or staging deploy that left
the base URL at its `zimmer.example.com` placeholder answers `503` on the metadata endpoints and
issues nothing. On a laptop with neither set, the issuer is `http://localhost:$PORT`. If you reach a dev box at any
other origin (a tailnet name, a tunnel), set `ZIMMER_LOCAL_BASE_URL` to it, or MCP clients will be
pointed at localhost.

## The 401

An unauthenticated `POST /mcp` answers:

```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer realm="zimmer", resource_metadata="https://zimmer.example.com/.well-known/oauth-protected-resource/mcp", scope="mcp"
```

A request that carried a credential Zimmer refused also gets `error="invalid_token"`. The body is the
API's usual error envelope. Nothing about the API-key path changes. A key in `X-API-Key` or in
`Authorization: Bearer` is checked exactly as before, and an OAuth access token is told apart by its
`zmr_oat_` prefix, which no key carries. `/mcp/external_app` sends no OAuth challenge, because it takes
only a plugin key.

## Seeing and revoking connections

**Settings → API keys** lists every connection under **MCP connections**. Each one shows the client,
who approved it, when it was last used, its level (**Acts on your behalf** or **Relay only**) with
when and how that level was set, and a **Revoke** button. A **Make relay only** or **Let it act on my
behalf** button changes the level. Raising it asks for confirmation first. The change is recorded on
the grant (`scope_changed_at`, `scope_change_reason`: `consent`, `ui_upgrade`, `ui_downgrade` or
`backfill`) and logged at WARN. Revoking refuses the access token from the next request on and ends
the refresh token, so the client has to be approved again. Like the rest of that page, it has no
REST or MCP sibling, for the same reason the key controls don't.

Connections approved before levels existed were raised to **acts on my behalf** by a one-time
[post-deploy task](/operate/deploying/#one-time-post-deploy-tasks)
(`LetExistingOauthGrantsActOnTheirApproversBehalf`). Each one shows *"raised by the one-time backfill
of existing connections"* until its level is changed.

Every grant, refusal and revocation is logged under `[oauth_server]`, naming the grant and the person,
never a token. A revocation is logged at WARN, so it ships to obs.

## Configuration

| Variable | Default | |
| --- | --- | --- |
| `OAUTH_SERVER_ISSUER` | the base URL (`ZIMMER_PROD_BASE_URL`) | The public origin Zimmer is reached at. Never taken from the request |
| `OAUTH_SERVER_ALLOWED_DOMAINS` | web sign-in's `ZIMMER_WEB_AUTH_ALLOWED_DOMAINS` | Who may approve a connection. Unset everywhere means nobody |
| `OAUTH_SERVER_ACCESS_TOKEN_TTL_SECONDS` | `3600` | |
| `OAUTH_SERVER_REFRESH_TOKEN_TTL_SECONDS` | `15552000` | 180 days |

Each value is read through the [secret chain](/operate/secrets-parameter-store/) on every request, so
a change needs no restart. None of them is a secret, so a store that cannot be reached falls back to
the process environment instead of failing the request.

What is not configured here: a signing key (tokens are random and stored as digests, so nothing is
signed) and a Google redirect URI (the identity step is the web UI's own sign-in, which has its own
callback).

See [Limitations](/limitations/#connecting-to-mcp-over-oauth) for the known edges.
