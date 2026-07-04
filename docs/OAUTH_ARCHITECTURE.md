# OAuth Architecture in Agent Orchestrator

> **Scope.** This document is about **MCP-server** OAuth — the credentials AO
> obtains so an MCP server (BigQuery, Linear, Notion, …) can act on the user's
> behalf. It is a *different system* from the OAuth that authenticates the
> **Claude Code CLI itself** (the Max-subscription login + account-rotation pool),
> which is documented in
> [`CLAUDE_CODE_OAUTH_ASSUMPTIONS.md`](CLAUDE_CODE_OAUTH_ASSUMPTIONS.md) and the
> rendered walkthrough [`AUTH_ROTATION_ARCHITECTURE.html`](AUTH_ROTATION_ARCHITECTURE.html).
> The Codex runtime equivalent is [`CODEX_AUTH.md`](CODEX_AUTH.md).

This document describes how OAuth authentication works in Agent Orchestrator for MCP servers that require OAuth credentials.

## Overview

Agent Orchestrator supports OAuth authentication for MCP servers through two mechanisms:

1. **Pre-registered OAuth** - Client credentials configured in Rails credentials for providers that don't support Dynamic Client Registration (DCR)
2. **Dynamic OAuth Discovery** - RFC 8414/9728 metadata discovery with optional DCR for providers that support it

## User Experience Flow

### Session Creation with OAuth-Required MCP Servers

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ 1. User creates a session with MCP servers requiring OAuth                  │
│    (e.g., BigQuery, Linear, Notion)                                         │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 2. Session enters "waiting" state with oauth_required metadata              │
│    - Lists which servers need OAuth credentials                             │
│    - Shows "Authorize" button for each server                               │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 3. User clicks "Authorize" for each MCP server                              │
│    - Initiates OAuth flow via McpOauthController#initiate                   │
│    - Creates McpOauthPendingFlow record with PKCE code verifier             │
│    - Redirects to OAuth provider's authorization URL                        │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 4. User authenticates with OAuth provider                                   │
│    - Provider shows consent screen                                          │
│    - User grants permissions                                                │
│    - Provider redirects back with authorization code                        │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 5. Callback handler exchanges code for tokens                               │
│    - McpOauthController#callback receives the code                          │
│    - Exchanges code for access_token and refresh_token                      │
│    - Stores credentials in McpOauthCredential                               │
│    - Deletes the pending flow                                               │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 6. Session auto-resumes when all OAuth flows complete                       │
│    - Credentials injected into Claude Code's ~/.claude/.credentials.json    │
│    - Session transitions from "waiting" to "running"                        │
│    - Agent job is re-queued                                                 │
└─────────────────────────────────────────────────────────────────────────────┘
```

## OAuth Flow Types

### 1. Pre-registered OAuth

Used for providers that don't support Dynamic Client Registration (DCR) or OAuth metadata discovery (RFC 8414/9728). All OAuth configuration (credentials and endpoints) is stored in Rails encrypted credentials.

**Configuration** (`config/credentials/{environment}.yml.enc`):
```yaml
mcp_oauth_clients:
  bigquery-pulsemcp:
    client_id: "your-client-id.apps.googleusercontent.com"
    client_secret: "GOCSPX-your-client-secret"
    authorization_endpoint: "https://accounts.google.com/o/oauth2/v2/auth"
    token_endpoint: "https://oauth2.googleapis.com/token"
    scopes: "https://www.googleapis.com/auth/bigquery"
```

**Required fields:** `client_id`, `client_secret`, `authorization_endpoint`, `token_endpoint`
**Optional fields:** `scopes`

**How it works:**
1. `PreregisteredOauthConfig.find_for_server(server_name)` looks up credentials
2. Server name must exactly match the key in credentials (e.g., "bigquery-pulsemcp")
3. All OAuth configuration (endpoints, scopes) comes from credentials - no hardcoding
4. Takes precedence over dynamic discovery

### 2. Dynamic OAuth Discovery (RFC 8414 / RFC 9728)

Used for providers that advertise OAuth metadata and optionally support DCR.

**Discovery order:**
1. RFC 8414: `/.well-known/oauth-authorization-server` (OAuth Authorization Server Metadata)
2. RFC 9728: `/.well-known/oauth-protected-resource` (Protected Resource Metadata)
3. OpenID Connect: `/.well-known/openid-configuration` (fallback)

**Dynamic Client Registration (RFC 7591):**
- If `registration_endpoint` is present in metadata, perform DCR
- Registers the application with redirect URI and requested grant types
- Obtains `client_id` and optionally `client_secret`

## Refresh Token Handling

### The Problem

OAuth 2.0 (RFC 6749) makes refresh tokens **optional** - the authorization server decides whether to issue them. Different providers have different mechanisms for requesting refresh tokens:

| Provider | Mechanism | Standard |
|----------|-----------|----------|
| Microsoft Azure AD | `offline_access` scope | OpenID Connect |
| Okta | `offline_access` scope | OpenID Connect |
| Keycloak | `offline_access` scope | OpenID Connect |
| Auth0 | `offline_access` scope | OpenID Connect |
| **Google** | `access_type=offline` parameter | **Proprietary** |

### Google's Proprietary Approach

Google OAuth does **not** support the standard OIDC `offline_access` scope. Instead, they require:
- `access_type=offline` - Tells Google to return a refresh token
- `prompt=consent` - Forces the consent screen to appear, guaranteeing a refresh token even for previously-authorized users

Without these parameters, Google only returns a short-lived access token (~1 hour).

**Google's documentation:** https://developers.google.com/identity/protocols/oauth2/web-server

### Our Solution

Agent Orchestrator automatically detects Google OAuth and adds the required parameters:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ Google OAuth Detection                                                       │
│ - If authorization_endpoint host is google.com or *.google.com              │
│ - Automatically adds access_type=offline and prompt=consent                 │
│ - Uses strict domain matching to prevent spoofed domains                    │
│ - Handles ANY Google OAuth flow (pre-registered or dynamic)                 │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                         (if not Google)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ Standard OIDC                                                               │
│ - Server's scopes_supported should include offline_access                   │
│ - Caller should include offline_access in requested scopes                  │
│ - Works for Microsoft, Okta, Keycloak, etc.                                 │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Implementation:** `McpOauthPendingFlow#authorization_url` and `McpOauthPendingFlow#google_oauth_provider?`

## Audience Binding — RFC 8707 Resource Indicator

The MCP authorization spec (2025-06-18) requires clients to send an RFC 8707
`resource` indicator on the authorize, token-exchange, and refresh requests. It
names the canonical MCP resource server the issued token is for. Servers that
**enforce audience binding** (e.g. Notion at `https://mcp.notion.com`) issue a
token at the authorization server but then reject it with `401 Unauthorized` at
the resource server if the `resource` indicator was missing — even though the
credential was just minted. Claude Code finds the injected credential
(`hasAuthProvider:true`), still gets a 401, and falls back to re-prompting for
auth inside the session.

### How the resource value is derived

1. During discovery (`McpOauthService#fetch_oauth_metadata`), the server's
   Protected Resource Metadata (RFC 9728,
   `/.well-known/oauth-protected-resource`) is fetched and its `resource` field
   captured — this is the canonical, PRM-advertised identifier (for Notion,
   `https://mcp.notion.com`, **not** the `/mcp` path).
2. If the PRM omits `resource`, AO falls back to the canonical MCP server URL
   (scheme + host + port + path, minus query/fragment and trailing slash) via
   `McpOauthService#canonical_resource`. The indicator is therefore always sent.

This is **general** — driven entirely by discovery, not a per-server special
case. Servers that don't enforce audience binding (e.g. Granola) advertise a
`resource` in their PRM too but ignore the indicator, so sending it is harmless.

### Persistence

The captured resource value is stored on `mcp_oauth_pending_flows.resource` (used
at authorize + token-exchange time) and copied to
`mcp_oauth_credentials.resource` (used at refresh time, since refreshes run later
from cron without re-running discovery).

**Implementation:** `McpOauthService#fetch_oauth_metadata` /
`#canonical_resource`, `McpOauthPendingFlow#authorization_url`,
`McpOauthService#exchange_code_for_tokens`, `McpOauthCredential#refresh!`.

## Key Components

### Models

**McpOauthPendingFlow**
- Stores in-flight OAuth flows while user authenticates
- Contains PKCE code verifier, state, endpoints, client credentials
- Expires after 24 hours
- Deleted after successful token exchange

**McpOauthCredential**
- Stores OAuth credentials (access_token, refresh_token, etc.)
- Keyed by server name and config hash
- Supports automatic token refresh when tokens expire

### Services

**PreregisteredOauthConfig**
- Loads pre-registered OAuth client configurations from Rails credentials
- All OAuth config (client credentials, endpoints, scopes) stored in credentials
- Server name must exactly match the credential key (e.g., "bigquery-pulsemcp")

**McpOauthService**
- OAuth metadata discovery (RFC 8414/9728)
- Dynamic Client Registration (RFC 7591)
- Token exchange

**McpOauthCredentialInjector**
- Injects OAuth credentials into Claude Code's credentials file
- Supports both macOS Keychain and file-based storage

### Controller

**McpOauthController**
- `initiate` - Starts OAuth flow, creates pending flow, redirects to provider
- `callback` - Handles OAuth callback, exchanges code for tokens
- `status` - Returns OAuth status for a session's MCP servers

## Database Schema

### mcp_oauth_pending_flows
```sql
CREATE TABLE mcp_oauth_pending_flows (
  id bigint PRIMARY KEY,
  session_id bigint NOT NULL REFERENCES sessions(id),
  server_name varchar NOT NULL,
  server_url varchar NOT NULL,
  state varchar NOT NULL UNIQUE,          -- CSRF protection & flow lookup
  code_verifier varchar NOT NULL,          -- PKCE
  authorization_endpoint varchar NOT NULL,
  token_endpoint varchar NOT NULL,
  registration_endpoint varchar,
  client_id varchar NOT NULL,
  client_secret varchar,
  redirect_uri varchar NOT NULL,
  scopes varchar,
  resource varchar,                        -- RFC 8707 resource indicator (audience binding)
  mcp_server_config jsonb NOT NULL,
  expires_at timestamp NOT NULL,
  created_at timestamp NOT NULL,
  updated_at timestamp NOT NULL
);
```

### mcp_oauth_credentials
```sql
CREATE TABLE mcp_oauth_credentials (
  id bigint PRIMARY KEY,
  credential_key varchar NOT NULL UNIQUE,  -- "name|hash" format
  server_name varchar NOT NULL,
  server_url varchar,
  client_id varchar NOT NULL,
  client_secret varchar,
  access_token varchar NOT NULL,
  refresh_token varchar,
  token_endpoint varchar,                  -- For refresh operations
  scopes varchar,
  resource varchar,                        -- RFC 8707 resource indicator (sent on refresh)
  expires_at timestamp,
  created_at timestamp NOT NULL,
  updated_at timestamp NOT NULL
);
```

## Security Considerations

1. **PKCE (RFC 7636)** - All OAuth flows use S256 code challenges
2. **State Parameter** - CSRF protection via random state parameter
3. **Credential Storage** - Tokens stored in database, not in session
4. **Secret Management** - Client secrets in Rails encrypted credentials
5. **Token Refresh** - Automatic refresh before expiration (15-minute threshold)

## Adding New OAuth Providers

### Pre-registered Provider

Add the full OAuth configuration to `config/credentials/{environment}.yml.enc`:
```yaml
mcp_oauth_clients:
  new_provider:
    client_id: "your-client-id"
    client_secret: "your-client-secret"
    authorization_endpoint: "https://provider.com/oauth/authorize"
    token_endpoint: "https://provider.com/oauth/token"
    scopes: "read write"  # optional
```

**Note:** For Google OAuth providers (authorization_endpoint containing google.com), refresh token parameters (`access_type=offline`, `prompt=consent`) are automatically added by `McpOauthPendingFlow#authorization_url` based on domain detection.

### Dynamic Provider

If the provider supports RFC 8414/9728 metadata discovery:
1. No configuration needed
2. OAuth metadata is discovered automatically
3. DCR is performed if registration_endpoint is present

## References

- [RFC 6749 - OAuth 2.0](https://datatracker.ietf.org/doc/html/rfc6749)
- [RFC 7591 - Dynamic Client Registration](https://datatracker.ietf.org/doc/html/rfc7591)
- [RFC 7636 - PKCE](https://datatracker.ietf.org/doc/html/rfc7636)
- [RFC 8414 - Authorization Server Metadata](https://datatracker.ietf.org/doc/html/rfc8414)
- [RFC 9728 - Protected Resource Metadata](https://datatracker.ietf.org/doc/html/rfc9728)
- [OpenID Connect Core 1.0](https://openid.net/specs/openid-connect-core-1_0.html) - offline_access scope
- [Google OAuth 2.0 for Web Server Apps](https://developers.google.com/identity/protocols/oauth2/web-server) - access_type=offline
- [MCP Authorization Specification](https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization)
