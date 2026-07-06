# MCP Server Fallback Elicitation Flow

This document describes the end-to-end flow for MCP server fallback elicitations in Agent Orchestrator. When an MCP server (e.g., Gmail) needs user approval before performing a sensitive action like sending an email, it uses this HTTP-based fallback protocol to request and receive confirmation.

## Overview

The MCP protocol supports native elicitation (built into the MCP client), but not all clients implement it. For clients that don't (like Claude Code at the time of writing), AO provides an HTTP fallback: the MCP server POSTs an approval request to AO, AO shows a banner to the user, and the MCP server polls until the user responds.

```
┌───────────────┐     ┌───────────────┐     ┌───────────────┐
│  MCP Server   │────▶│  Agent        │────▶│  User         │
│  (Gmail)      │◀────│  Orchestrator │◀────│  (Browser)    │
└───────────────┘     └───────────────┘     └───────────────┘
   POST request          Store & show          Accept/Decline
   Poll for answer       Broadcast banner      via Turbo Streams
```

## Architecture

### Environment Variables

Two sources of configuration connect the pieces:

**Static (in `config/mcp.json`, per-server):**

| Variable | Value | Purpose |
|----------|-------|---------|
| `ELICITATION_ENABLED` | `"true"` | Tells the MCP server's elicitation library to activate |
| `ELICITATION_REQUEST_URL` | `https://zimmer.example.com/api/v1/elicitations` | Where the MCP server POSTs approval requests |
| `ELICITATION_POLL_URL` | `https://zimmer.example.com/api/v1/elicitations` | Where the MCP server polls for responses |

**Dynamic (injected at runtime by `ClaudeCliAdapter#configure_elicitation_env`):**

| Variable | Value | Purpose |
|----------|-------|---------|
| `ELICITATION_SESSION_ID` | `session.id` (e.g., `123`) | Per-session identifier; the `@pulsemcp/mcp-elicitation` library reads this and auto-includes it as `com.pulsemcp/session-id` in `_meta` of HTTP fallback requests, so AO can link elicitation requests back to the correct session |

`ELICITATION_SESSION_ID` is set on the Claude CLI process environment. MCP servers, as child processes, inherit it automatically. The env var name is orchestrator-agnostic — it follows the `ELICITATION_*` naming convention used by the library.

### Key Files

| File | Purpose |
|------|---------|
| `config/mcp.json` | MCP server catalog with elicitation env vars |
| `app/services/claude_cli_adapter.rb` | Injects `ELICITATION_SESSION_ID` into the Claude CLI process |
| `app/services/process_lifecycle_manager.rb` | Sets `ao_session_id` on the CLI adapter from `session.id` |
| `app/controllers/api/v1/elicitations_controller.rb` | API endpoints: `POST` (create) and `GET` (poll) |
| `app/controllers/elicitations_controller.rb` | Web controller: `PATCH` (user responds) |
| `app/models/elicitation.rb` | Model with status lifecycle and poll response formatting |
| `app/services/broadcast_service.rb` | Turbo Stream broadcasts for real-time UI updates |
| `app/views/elicitations/_elicitation_banner.html.erb` | Banner UI with dynamic form fields |
| `app/javascript/controllers/elicitation_form_controller.js` | Stimulus controller for form interaction |

### Routes

```ruby
# API routes (consumed by MCP servers)
namespace :api do
  namespace :v1 do
    resources :elicitations, only: [:create, :show]
    # POST   /api/v1/elicitations          => create elicitation request
    # GET    /api/v1/elicitations/:id       => poll by request_id
  end
end

# Web routes (consumed by user's browser)
resources :elicitations, only: [] do
  member do
    patch :respond, action: :respond_to_elicitation
    # PATCH  /elicitations/:id/respond      => user accepts/declines
  end
end
```

## End-to-End Flow

### Step 1: Session Setup

When AO starts a new agent session, it spawns a Claude CLI process:

```
ProcessLifecycleManager                  ClaudeCliAdapter
       │                                       │
       │  cli_adapter.ao_session_id = 123      │
       │──────────────────────────────────────▶│
       │                                       │
       │  configure_elicitation_env(env_vars)  │
       │                                       │
       │              env_vars["ELICITATION_SESSION_ID"] = "123"
       │                                       │
       │  spawn Claude CLI with env_vars       │
       │──────────────────────────────────────▶│
```

Claude CLI starts the MCP servers defined in `config/mcp.json`. Each Gmail server inherits `ELICITATION_SESSION_ID=123` from the parent process and gets its own env from the config:

```
Claude CLI process (ELICITATION_SESSION_ID=123)
  │
  ├── Gmail MCP Server (child process)
  │     env:
  │       ELICITATION_SESSION_ID=123  (inherited from parent)
  │       ELICITATION_ENABLED=true    (from mcp.json)
  │       ELICITATION_REQUEST_URL=https://zimmer.example.com/api/v1/elicitations
  │       ELICITATION_POLL_URL=https://zimmer.example.com/api/v1/elicitations
  │
  ├── Other MCP servers...
```

### Step 2: MCP Server Requests Approval

When the Gmail MCP server's `send_email` tool is invoked, the `@pulsemcp/mcp-elicitation` library checks if elicitation is enabled. If so, it builds the `_meta` (auto-including `com.pulsemcp/session-id` from `ELICITATION_SESSION_ID` if set) and POSTs to AO:

```
POST https://zimmer.example.com/api/v1/elicitations
X-API-Key: <from API_KEYS env>
Content-Type: application/json

{
  "message": "Send email to john@example.com with subject: Project Update",
  "mode": "form",
  "requestedSchema": {
    "type": "object",
    "properties": {
      "confirm_send": {
        "type": "boolean",
        "title": "Confirm sending this email"
      }
    },
    "required": ["confirm_send"]
  },
  "_meta": {
    "com.pulsemcp/request-id": "req_abc123def456",
    "com.pulsemcp/session-id": "123",
    "com.pulsemcp/tool-name": "send_email",
    "com.pulsemcp/context": "User asked to send a project update email...",
    "com.pulsemcp/expires-at": "2026-03-09T10:15:00Z"
  }
}
```

Key `_meta` fields:

| Field | Purpose |
|-------|---------|
| `com.pulsemcp/request-id` | Unique identifier for this elicitation; used for polling |
| `com.pulsemcp/session-id` | Session identifier (auto-populated by the library from `ELICITATION_SESSION_ID` env var); links the request to the correct session |
| `com.pulsemcp/tool-name` | Which MCP tool triggered this elicitation |
| `com.pulsemcp/context` | LLM-generated explanation for the user |
| `com.pulsemcp/expires-at` | When the request expires (optional; defaults to 10 minutes) |

### Step 3: AO Creates Elicitation Record

`Api::V1::ElicitationsController#create` handles the POST:

1. **Authenticates** via `X-API-Key` header (from `API_KEYS` env var)
2. **Validates** required fields (`_meta[com.pulsemcp/request-id]` and `message`)
3. **Finds session** using `_meta[com.pulsemcp/session-id]`:
   - Tries numeric ID lookup first: `Session.find_by(id: 123)`
   - Falls back to slug lookup: `Session.find_by(slug: "123")`
4. **Creates** an `Elicitation` record in the database (status: `pending`)
5. **Sends push notification** via `SendPushNotificationJob`
6. **Broadcasts** the elicitation banner to the session page via ActionCable

Response to the MCP server:

```json
{
  "action": "pending",
  "_meta": {
    "com.pulsemcp/request-id": "req_abc123def456",
    "com.pulsemcp/poll-url": "https://zimmer.example.com/api/v1/elicitations/req_abc123def456"
  }
}
```

### Step 4: User Sees the Banner

The session detail page (`/sessions/123`) subscribes to a Turbo Stream channel:

```erb
<%= turbo_stream_from "session_123_elicitations" %>
```

When AO broadcasts the elicitation, a banner appears in real-time (no page reload needed):

```
┌─────────────────────────────────────────────────────────┐
│ ⚠ Action Approval Required              [send_email]   │
│                                                         │
│ Send email to john@example.com with subject:            │
│ Project Update                                          │
│                                                         │
│ User asked to send a project update email...            │
│                                                         │
│ ☐ Confirm sending this email *                          │
│                                                         │
│ [✓ Accept]  [✗ Decline]                                 │
└─────────────────────────────────────────────────────────┘
```

The banner includes:
- **Tool name badge** (e.g., `send_email`)
- **Human-readable message** from the MCP server
- **Context** (LLM explanation, shown in italics)
- **Dynamic form fields** rendered from `requestedSchema` (supports boolean, string, string+enum, number, integer)
- **Accept/Decline buttons**

If the user loads the page while elicitations are already pending, they render server-side:

```ruby
@session.elicitations.active.each do |elicitation|
  render "elicitations/elicitation_banner", elicitation: elicitation, session: @session
end
```

### Step 5: MCP Server Polls

Meanwhile, the MCP server polls the `poll-url` every ~2 seconds:

```
GET https://zimmer.example.com/api/v1/elicitations/req_abc123def456
X-API-Key: <from API_KEYS env>
```

While pending:

```json
{
  "action": "pending",
  "content": null,
  "_meta": {
    "com.pulsemcp/request-id": "req_abc123def456"
  }
}
```

### Step 6: User Responds

When the user clicks Accept or Decline, the Stimulus controller (`elicitation_form_controller.js`):

1. **Collects form field values** based on data attributes (`data-field-name`, `data-field-type`)
2. **Disables buttons** to prevent double-submit
3. **Submits** via `fetch` with Turbo Stream accept header:

```
PATCH /elicitations/42/respond
Content-Type: multipart/form-data

action_type=accept
content={"confirm_send":true}
```

`ElicitationsController#respond_to_elicitation` processes the response:

1. **Validates** the elicitation is still pending
2. **Validates** the action type is "accept" or "decline"
3. **Parses** the content JSON
4. **Resolves** the elicitation: `elicitation.resolve!(action: "accept", content: {...})`
   - Updates `status` to "accept"
   - Stores `response_content` (the form field values)
   - Sets `responded_at` to current time
5. **Broadcasts** banner removal via Turbo Streams (DOM node removed)

### Step 7: MCP Server Gets the Answer

On the next poll, AO returns the resolved response:

**If accepted:**

```json
{
  "action": "accept",
  "content": {
    "confirm_send": true
  },
  "_meta": {
    "com.pulsemcp/request-id": "req_abc123def456",
    "com.pulsemcp/responded-at": "2026-03-09T10:12:00Z"
  }
}
```

**If declined:**

```json
{
  "action": "decline",
  "content": null,
  "_meta": {
    "com.pulsemcp/request-id": "req_abc123def456",
    "com.pulsemcp/responded-at": "2026-03-09T10:12:00Z"
  }
}
```

The MCP server then either proceeds with the action (accept) or cancels it (decline).

## Elicitation Lifecycle

```
                    ┌─────────┐
          POST      │         │   User accepts
  ───────────────▶  │ pending │ ─────────────────▶ accepted
                    │         │
                    └────┬────┘
                         │
                    ┌────┴────┐
                    │         │
           User     │         │   Time > expires_at
           declines │         │   (auto on next poll)
                    ▼         ▼
                declined   expired
```

### States

| Status | Description |
|--------|-------------|
| `pending` | Awaiting user response |
| `accepted` | User approved the action |
| `declined` | User rejected the action |
| `cancelled` | Programmatically cancelled (reserved) |
| `expired` | No response within TTL (default 10 minutes) |

### Expiration

Elicitations expire if the user doesn't respond within the TTL. The default is 10 minutes (`Elicitation::DEFAULT_EXPIRATION`). The MCP server can override this via `_meta[com.pulsemcp/expires-at]`.

Expiration is lazy — it happens when the MCP server next polls:

```ruby
# In Api::V1::ElicitationsController#show
elicitation.expire_if_needed!
# => updates status to "expired" if pending? && expires_at <= Time.current
```

The `active` scope excludes expired elicitations from the UI:

```ruby
scope :active, -> { pending.where("expires_at > ?", Time.current) }
```

## Session Linkage

The critical question: how does AO know which session an elicitation belongs to?

```
AO Session #123
    │
    ├── ProcessLifecycleManager sets cli_adapter.ao_session_id = session.id
    │
    ├── ClaudeCliAdapter injects ELICITATION_SESSION_ID=123 into process env
    │
    ├── Claude CLI spawns MCP servers as child processes
    │   └── Child processes inherit ELICITATION_SESSION_ID=123
    │
    ├── @pulsemcp/mcp-elicitation library reads process.env.ELICITATION_SESSION_ID
    │   └── Auto-includes in POST as _meta["com.pulsemcp/session-id"]: "123"
    │
    ├── AO controller extracts _meta["com.pulsemcp/session-id"]
    │   └── Session.find_by(id: 123)
    │
    └── Elicitation created with session_id: 123
        └── Broadcast to ActionCable channel "session_123_elicitations"
            └── User viewing /sessions/123 sees the banner
```

`ELICITATION_SESSION_ID` is the **only** runtime-injected env var for elicitations. Everything else (URLs, enabled flag) is hardcoded in `config/mcp.json`.

## API Authentication

Both the POST and GET endpoints inherit from `Api::BaseController`, which enforces API key authentication:

```
X-API-Key: <key>
```

The key is validated against the `API_KEYS` environment variable (comma-separated list of valid keys).

## Currently Supported Servers

Only Gmail MCP servers currently support elicitations (via `@pulsemcp/mcp-elicitation`):

- `gmail-tadas-readonly`, `gmail-tadas-readwrite`, `gmail-tadas-readwrite-external`
- `gmail-tadas412-readonly`, `gmail-tadas412-readwrite`, `gmail-tadas412-readwrite-external`
- `gmail-pulsemcp-readonly`, `gmail-pulsemcp-readwrite`, `gmail-pulsemcp-readwrite-external`

To add elicitation support to a new MCP server:
1. Integrate the `@pulsemcp/mcp-elicitation` library in the server
2. Add the three elicitation env vars to its entry in `config/mcp.json`
