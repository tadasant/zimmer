# Zimmer REST API

This document describes the REST API for programmatically controlling agent sessions in the Zimmer.

## Base URL

All API endpoints are prefixed with `/api/v1`.

```
https://your-domain.com/api/v1
```

## Authentication

All API requests require authentication via an API key passed in the `X-API-Key` header.

```bash
curl -H "X-API-Key: your_api_key" https://your-domain.com/api/v1/sessions
```

### Configuring API Keys

API keys are configured via the `API_KEYS` environment variable as a comma-separated list:

```bash
# Single key
API_KEYS=my_secret_key_123

# Multiple keys
API_KEYS=key1,key2,key3
```

Generate secure API keys with:

```bash
bin/rails runner "puts SecureRandom.hex(32)"
```

### Error Response

If authentication fails, the API returns:

```json
{
  "error": "Unauthorized",
  "message": "Invalid or missing API key"
}
```

**Status Code:** `401 Unauthorized`

---

## Terminology

A few naming notes that affect how this API reads:

- **Archived sessions are referred to as "trash" in the UI and in some response messages**, but the underlying status enum value is `archived` and the timestamp column is `archived_at`. When you archive a session, the response message will say "Session moved to trash" and a `trash_after` timestamp is returned indicating when the session's clone will be automatically cleaned up. Filter parameters and status values are always `archived`, never `trash`.
- **`git_root`** is the repository URL or local path on a session — a free-form string. **`agent_root`** is the name of a preconfigured catalog entry (e.g., `agent-orchestrator`, `ao-router`) that resolves to a `git_root` plus defaults for `branch`, `subdirectory`, `mcp_servers`, `catalog_skills`, `catalog_hooks`, `catalog_plugins`, and `model`. You can pass either when creating a session — passing `agent_root` is the recommended way to spawn sessions on configured roots.

---

## Common Response Formats

### Pagination

List endpoints support pagination with the following query parameters:

| Parameter | Type | Default | Max | Description |
|-----------|------|---------|-----|-------------|
| `page` | integer | 1 | - | Page number |
| `per_page` | integer | 25 | 100 | Results per page |

Paginated responses include a `pagination` object:

```json
{
  "sessions": [...],
  "pagination": {
    "page": 1,
    "per_page": 25,
    "total_count": 150,
    "total_pages": 6
  }
}
```

### Error Responses

**Validation Error (422 Unprocessable Entity):**
```json
{
  "error": "Validation failed",
  "messages": ["Prompt is too long (maximum 500,000 characters)"]
}
```

**Not Found (404 Not Found):**
```json
{
  "error": "Not Found",
  "message": "The requested resource was not found"
}
```

### Timestamps

All timestamps are returned in ISO 8601 format:
```
"2025-01-15T14:30:00Z"
```

---

## Sessions

Sessions represent agent execution contexts. Each session tracks an agent's lifecycle from creation through completion or failure.

### Session Object

| Field | Type | Description |
|-------|------|-------------|
| `id` | integer | Unique session ID |
| `slug` | string | URL-friendly identifier (optional) |
| `title` | string | Session display title |
| `status` | string | Current status: `waiting`, `running`, `needs_input`, `failed`, `archived` |
| `agent_runtime` | string | Agent runtime (currently only `claude_code`) |
| `prompt` | string | Initial prompt or latest follow-up |
| `git_root` | string | Repository URL or local path |
| `branch` | string | Git branch name |
| `subdirectory` | string | Subdirectory within the repository |
| `execution_provider` | string | `local_filesystem` or `remote_sandbox` |
| `goal` | string | Goal for the session |
| `mcp_servers` | array | List of MCP server names |
| `catalog_skills` | array | List of skill names selected from the catalog |
| `catalog_hooks` | array | List of hook names selected from the catalog |
| `catalog_plugins` | array | List of plugin IDs selected from the catalog |
| `config` | object | Additional configuration (e.g., `model`) |
| `metadata` | object | System metadata (clone_path, exit_status, agent_root_key, etc.) |
| `custom_metadata` | object | User-defined metadata |
| `is_autonomous` | boolean | Whether the heartbeat agent manages this session |
| `auto_compact_window` | integer | Token threshold for auto-compaction |
| `category_id` | integer | ID of the category this session belongs to (null when Uncategorized) |
| `category` | object | Compact category summary (`id`, `name`, `position`, `is_frozen`), or null when Uncategorized |
| `session_id` | string | Claude Code session ID |
| `job_id` | string | Background job ID for initial run |
| `running_job_id` | string | Background job ID for follow-up runs |
| `archived_at` | string | ISO 8601 timestamp when archived (null otherwise) |
| `trash_after` | string | ISO 8601 timestamp when clone will be auto-cleaned (null otherwise) |
| `session_notes` | string | Free-form notes attached to the session |
| `session_notes_updated_at` | string | ISO 8601 timestamp when notes were last updated |
| `favorited` | boolean | Whether the session is marked as favorite |
| `created_at` | string | ISO 8601 creation timestamp |
| `updated_at` | string | ISO 8601 last update timestamp |

### List Sessions

```
GET /api/v1/sessions
```

**Query Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `status` | string | Filter by status |
| `agent_runtime` | string | Filter by agent runtime |
| `show_archived` | boolean | Include archived (trashed) sessions (default: `false`) |
| `page` | integer | Page number |
| `per_page` | integer | Results per page (max: 100) |

**Example Request:**
```bash
curl -H "X-API-Key: your_key" \
  "https://your-domain.com/api/v1/sessions?status=running&per_page=10"
```

**Example Response:**
```json
{
  "sessions": [
    {
      "id": 1,
      "slug": "fix-auth-bug-20250115-1430",
      "title": "Fix authentication bug",
      "status": "running",
      "agent_runtime": "claude_code",
      "prompt": "Fix the login authentication bug",
      "git_root": "https://github.com/example/repo.git",
      "branch": "main",
      "subdirectory": null,
      "execution_provider": "local_filesystem",
      "goal": null,
      "mcp_servers": ["playwright-custom"],
      "catalog_skills": [],
      "catalog_hooks": [],
      "catalog_plugins": [],
      "config": {"model": "opus"},
      "metadata": {"clone_path": "repo-main-123"},
      "custom_metadata": {},
      "is_autonomous": false,
      "auto_compact_window": 150000,
      "category_id": 3,
      "category": {"id": 3, "name": "Auth work", "position": 0, "is_frozen": false},
      "session_id": "abc123",
      "job_id": "job_456",
      "running_job_id": null,
      "archived_at": null,
      "trash_after": null,
      "session_notes": null,
      "session_notes_updated_at": null,
      "favorited": false,
      "created_at": "2025-01-15T14:30:00Z",
      "updated_at": "2025-01-15T14:35:00Z"
    }
  ],
  "pagination": {
    "page": 1,
    "per_page": 10,
    "total_count": 1,
    "total_pages": 1
  }
}
```

### Search Sessions

```
GET /api/v1/sessions/search
```

Search sessions by query string. Searches across session title, metadata, and custom_metadata. Optionally search transcript contents.

**Query Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `q` | string | **Required.** Search query (max 1000 characters) |
| `search_contents` | string | Set to `"true"` to also search transcript contents (default: `"false"`) |
| `status` | string | Filter by status |
| `agent_runtime` | string | Filter by agent runtime |
| `show_archived` | string | Set to `"true"` to include archived sessions (default: `"false"`) |
| `page` | integer | Page number |
| `per_page` | integer | Results per page (max: 100) |

**Performance Notes:**
- Search performs text matching on title, metadata, and custom_metadata fields
- Enabling `search_contents=true` searches transcript contents, which may be slow for sessions with large transcripts
- For best performance with large datasets, consider narrowing searches with status or agent_runtime filters

**Example Request:**
```bash
curl -H "X-API-Key: your_key" \
  "https://your-domain.com/api/v1/sessions/search?q=authentication&search_contents=true"
```

**Example Response:**
```json
{
  "query": "authentication",
  "search_contents": true,
  "sessions": [
    {
      "id": 1,
      "slug": "fix-auth-bug-20250115-1430",
      "title": "Fix authentication bug",
      "status": "needs_input"
    }
  ],
  "pagination": {
    "page": 1,
    "per_page": 25,
    "total_count": 1,
    "total_pages": 1
  }
}
```

**Error Response (Missing Query):**
```json
{
  "error": "Missing parameter",
  "message": "q (search query) is required"
}
```

**Status Code:** `400 Bad Request`

---

### Dependency Graph

```
GET /api/v1/sessions/dependency_graph
```

Returns a structured dependency graph of all non-archived sessions, capturing parent-child (invocation chain), blocking, and origin relationships. Designed for the heartbeat agent to get a full picture of session topology in a single API call.

**Query Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `include_archived` | string | Set to `"true"` to include archived sessions (default: `"false"`) |

**Example Request:**
```bash
curl -H "X-API-Key: your_key" \
  "https://your-domain.com/api/v1/sessions/dependency_graph"
```

**Example Response:**
```json
{
  "dependency_graph": {
    "nodes": [
      {
        "id": 555,
        "slug": "user-task-20260220",
        "title": "Fix login bug",
        "status": "running",
        "is_autonomous": true,
        "origin_type": "user-triggered",
        "parent_session_id": null,
        "spawned_by": null,
        "created_at": "2026-02-20T10:00:00Z",
        "updated_at": "2026-02-20T10:30:00Z"
      }
    ],
    "edges": [
      {
        "type": "spawned",
        "from_id": 556,
        "to_id": 559,
        "label": "spawned"
      }
    ],
    "roots": [555, 556],
    "summary": {
      "total": 3,
      "by_status": {"running": 1, "archived": 1, "needs_input": 1},
      "by_origin_type": {"user-triggered": 1, "heartbeat-triggered": 1, "router-triggered": 1}
    }
  }
}
```

**Node Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `id` | integer | Session ID |
| `slug` | string | URL-friendly identifier |
| `title` | string | Session title |
| `status` | string | Current status (running, needs_input, failed, etc.) |
| `is_autonomous` | boolean | Whether the heartbeat manages this session |
| `origin_type` | string | How the session was created: `user-triggered`, `heartbeat-triggered`, `router-triggered`, or `agent-triggered` |
| `parent_session_id` | integer/null | ID of the session that spawned this one |
| `spawned_by` | string/null | Value of `custom_metadata.spawned_by` |

**Edge Types:**

| Type | Description |
|------|-------------|
| `spawned` | Parent-child invocation chain. `from_id` spawned `to_id`. |
| `blocked_by` | `from_id` is blocked on `to_id`. Detected from prompt/goal text referencing other session IDs. |

---

### Get Session

```
GET /api/v1/sessions/:id
```

The `:id` parameter can be either the numeric ID or the session slug.

**Query Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `include_transcript` | boolean | Include full transcript (default: `false`) |

**Example Request:**
```bash
curl -H "X-API-Key: your_key" \
  "https://your-domain.com/api/v1/sessions/1?include_transcript=true"
```

**Example Response:**
```json
{
  "session": {
    "id": 1,
    "slug": "fix-auth-bug-20250115-1430",
    "title": "Fix authentication bug",
    "status": "running",
    "transcript": "{\"type\":\"user\",...}\n{\"type\":\"assistant\",...}"
  }
}
```

### Create Session

```
POST /api/v1/sessions
```

Creates a new session. If a `prompt` is provided, the agent job is automatically queued.

**Request Body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `agent_root` | string | No | Agent root name (resolves `git_root`, `branch`, `subdirectory`, `mcp_servers`, `catalog_skills`, `catalog_hooks`, `catalog_plugins`, and `model` from the catalog) |
| `agent_runtime` | string | No | Per-spawn runtime override. When omitted, resolution falls through the `agent_root`'s `default_runtime`, then the global session default (configured on the Settings page), then `claude_code`. Must be a registered runtime; an unregistered value returns 422. |
| `prompt` | string | No | Initial prompt (omit for clone-only session) |
| `git_root` | string | No | Repository URL or path (overrides `agent_root`'s URL if both provided) |
| `branch` | string | No | Git branch (default: `main` or agent root's default) |
| `subdirectory` | string | No | Subdirectory within repo |
| `title` | string | No | Session title |
| `slug` | string | No | URL-friendly identifier |
| `goal` | string | No | Goal for the session |
| `execution_provider` | string | No | `local_filesystem` or `remote_sandbox` |
| `mcp_servers` | array | No | List of MCP server names (overrides agent root defaults) |
| `catalog_skills` | array | No | List of skill names (overrides agent root defaults) |
| `catalog_hooks` | array | No | List of hook names (overrides agent root defaults) |
| `catalog_plugins` | array | No | List of plugin IDs (overrides agent root defaults) |
| `config` | object | No | Additional configuration (e.g., `{"model": "sonnet"}`). When `model` is omitted, it resolves to the agent root's default, then the global session default (Settings page), then the runtime's catalog default; a model incompatible with the resolved runtime is replaced by that fallback. |
| `custom_metadata` | object | No | User-defined metadata |
| `is_autonomous` | boolean | No | Heartbeat-managed flag |
| `parent_session_id` | integer | No | ID of the session that spawned this one |
| `auto_compact_window` | integer | No | Custom auto-compact threshold |

**Example Request (with explicit git_root):**
```bash
curl -X POST -H "X-API-Key: your_key" \
  -H "Content-Type: application/json" \
  -d '{
    "agent_runtime": "claude_code",
    "prompt": "Add unit tests for the User model",
    "git_root": "https://github.com/example/repo.git",
    "branch": "main",
    "title": "Add User model tests",
    "mcp_servers": ["playwright-custom"],
    "custom_metadata": {"ticket_id": "PROJ-123"}
  }' \
  "https://your-domain.com/api/v1/sessions"
```

**Example Request (with agent_root):**
```bash
curl -X POST -H "X-API-Key: your_key" \
  -H "Content-Type: application/json" \
  -d '{
    "agent_root": "agent-orchestrator",
    "prompt": "Add unit tests for the Session model"
  }' \
  "https://your-domain.com/api/v1/sessions"
```

**Example Response:**
```json
{
  "session": {
    "id": 2,
    "title": "Add User model tests",
    "status": "waiting",
    "job_id": "job_789"
  }
}
```

**Status Code:** `201 Created`

### Update Session

```
PATCH /api/v1/sessions/:id
```

Updates session attributes. Only certain fields can be updated via this endpoint; other fields use dedicated endpoints (see below).

**Updatable Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `title` | string | Session title |
| `slug` | string | URL-friendly identifier |
| `goal` | string | Goal for the session |
| `is_autonomous` | boolean | Heartbeat-managed flag |
| `custom_metadata` | object | User-defined metadata |

For other fields, use:
- `PATCH /api/v1/sessions/:id/mcp_servers` — update MCP servers
- `PATCH /api/v1/sessions/:id/catalog_skills` — update skills
- `PATCH /api/v1/sessions/:id/catalog_hooks` — update hooks
- `PATCH /api/v1/sessions/:id/catalog_plugins` — update plugins
- `PATCH /api/v1/sessions/:id/model` — update model
- `PATCH /api/v1/sessions/:id/notes` — update session notes

**Example Request:**
```bash
curl -X PATCH -H "X-API-Key: your_key" \
  -H "Content-Type: application/json" \
  -d '{"title": "Updated title", "custom_metadata": {"priority": "high"}}' \
  "https://your-domain.com/api/v1/sessions/1"
```

### Delete Session

```
DELETE /api/v1/sessions/:id
```

Permanently deletes a session and all associated logs and transcripts.

**Example Request:**
```bash
curl -X DELETE -H "X-API-Key: your_key" \
  "https://your-domain.com/api/v1/sessions/1"
```

**Status Code:** `204 No Content`

### Archive (Trash) Session

```
POST /api/v1/sessions/:id/archive
```

Archives a session (moves it to trash). Can be called on sessions in `waiting`, `running`, `needs_input`, or `failed` status.

The session's status becomes `archived` and a `trash_after` timestamp is set, indicating when its clone directory will be automatically cleaned up. Clean clones are deleted immediately after a short undo window; clones with unpushed artifacts are preserved for `TRASH_RETENTION_PERIOD` (currently 4 days).

**Example Request:**
```bash
curl -X POST -H "X-API-Key: your_key" \
  "https://your-domain.com/api/v1/sessions/1/archive"
```

**Example Response:**
```json
{
  "session": {
    "id": 1,
    "status": "archived",
    "archived_at": "2025-01-15T15:00:00Z",
    "trash_after": "2025-01-29T15:00:00Z"
  },
  "message": "Session moved to trash",
  "trash_after": "2025-01-29T15:00:00Z"
}
```

### Unarchive (Restore from Trash) Session

```
POST /api/v1/sessions/:id/unarchive
```

Restores an archived session from trash. Recreates the clone directory if needed and restores the transcript so Claude Code can resume where it left off.

**Example Request:**
```bash
curl -X POST -H "X-API-Key: your_key" \
  "https://your-domain.com/api/v1/sessions/1/unarchive"
```

**Example Response:**
```json
{
  "session": { "id": 1, "status": "needs_input" },
  "clone_restored": true,
  "message": "Session restored from trash with clone restored"
}
```

### Bulk Archive

```
POST /api/v1/sessions/bulk_archive
```

Archive multiple sessions at once.

**Request Body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `session_ids` | array | Yes | Array of session IDs to archive |

**Example Request:**
```bash
curl -X POST -H "X-API-Key: your_key" \
  -H "Content-Type: application/json" \
  -d '{"session_ids": [1, 2, 3]}' \
  "https://your-domain.com/api/v1/sessions/bulk_archive"
```

**Example Response:**
```json
{
  "archived_count": 3,
  "errors": []
}
```

### Send Follow-up Prompt

```
POST /api/v1/sessions/:id/follow_up
```

Sends a follow-up prompt to a session. Behavior depends on session status:

- **`needs_input`** or **`waiting`**: Sent immediately.
- **`running`**: Queued as an enqueued message; processed when the agent finishes the current turn.
- **`failed`** / **`archived`**: Returns an error.

Pass `force_immediate: true` to interrupt a running session and deliver the prompt now. This routes through the same race-free interrupt backend as the web "Send Now" button: the prompt is staged as an enqueued message and the running turn is terminated so the interrupting message is picked up immediately. Delivery is exactly-once and FIFO-ordered with any other interrupts. The session's stored `prompt` field is not overwritten by a follow-up.

**Request Body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `prompt` | string | Yes | The follow-up prompt (max 500,000 characters) |
| `goal` | string | No | Override the session's goal for this turn. Omitting or sending an empty string preserves the session's existing goal — use `PATCH /api/v1/sessions/:id` to explicitly change or clear it. |
| `force_immediate` | boolean | No | If true, interrupts a running session to deliver the prompt now (default: false) |

**Example Request:**
```bash
curl -X POST -H "X-API-Key: your_key" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Now add integration tests as well"}' \
  "https://your-domain.com/api/v1/sessions/1/follow_up"
```

**Response (immediate):**
```json
{
  "session": {"id": 1, "status": "running"},
  "message": "Follow-up prompt sent"
}
```

**Response (queued, status 202):**
```json
{
  "session": {"id": 1, "status": "running"},
  "enqueued_message": {"id": 7, "position": 1, "status": "pending"},
  "message": "Message queued (session is running). It will be sent when the agent completes its current task."
}
```

**Response (`force_immediate` success):**
```json
{
  "session": {"id": 1, "status": "running"},
  "message": "Follow-up prompt sent immediately"
}
```

**`force_immediate` errors:** when the interrupt cannot be dispatched, the staged message is discarded (never delivered later as a surprise queued follow-up) and the call returns an error:

| Status | When |
|--------|------|
| `404 Not Found` | The staged message could not be found when dispatch began (e.g. a concurrent interrupt already claimed it) |
| `409 Conflict` | The session is in a state that cannot be interrupted (e.g. it just finished, or a concurrent interrupt is in flight) |
| `422 Unprocessable Entity` | The request is understood but cannot be applied to the session |
| `500 Internal Server Error` | An unexpected failure while dispatching the interrupt |

```json
{
  "error": "Cannot send follow-up",
  "message": "Session is not in a running state"
}
```

### Pause Session

```
POST /api/v1/sessions/:id/pause
```

Pauses a running session, transitioning it to `needs_input` status.

**Example Request:**
```bash
curl -X POST -H "X-API-Key: your_key" \
  "https://your-domain.com/api/v1/sessions/1/pause"
```

### Sleep Session

```
POST /api/v1/sessions/:id/sleep
```

Puts a session to sleep (transitions to `waiting`). Used by the "wake me up later" workflow — a one-time schedule trigger will resume it at the specified time. Accepts both `needs_input` (immediate sleep) and `running` (deferred sleep — takes effect when the current turn ends).

**Example Request:**
```bash
curl -X POST -H "X-API-Key: your_key" \
  "https://your-domain.com/api/v1/sessions/1/sleep"
```

### Restart Session

```
POST /api/v1/sessions/:id/restart
```

Restarts a paused or failed session. Clears stale retry metadata and re-queues the agent job. If setup never completed (e.g., git clone failed), the full setup pipeline is re-run from scratch.

**Example Request:**
```bash
curl -X POST -H "X-API-Key: your_key" \
  "https://your-domain.com/api/v1/sessions/1/restart"
```

**Example Response:**
```json
{
  "session": {"id": 1, "status": "running"},
  "message": "Session restarted"
}
```

### Fork Session

```
POST /api/v1/sessions/:id/fork
```

Creates a new session branching from a specific message index in the source session's transcript.

**Request Body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `message_index` | integer | Yes | Index of the transcript message to fork from |

**Example Request:**
```bash
curl -X POST -H "X-API-Key: your_key" \
  -H "Content-Type: application/json" \
  -d '{"message_index": 42}' \
  "https://your-domain.com/api/v1/sessions/1/fork"
```

**Status Code:** `201 Created`

### Refresh Session

```
POST /api/v1/sessions/:id/refresh
```

Re-reads the session's transcript from the filesystem and updates the database. Useful when the database transcript may be stale (e.g., after a restart).

Never replaces the stored transcript with a shorter filesystem one. When a clone is recreated at a new path the runtime starts a fresh, shorter transcript file; since the stored transcript is the only durable record, the longer stored transcript is preserved (the response shape is unchanged — `session` plus a `message` noting the stored transcript was kept).

**Example Request:**
```bash
curl -X POST -H "X-API-Key: your_key" \
  "https://your-domain.com/api/v1/sessions/1/refresh"
```

### Bulk Refresh All Sessions

```
POST /api/v1/sessions/refresh_all
```

Bulk operation: restart failed sessions, continue auto-continuable paused sessions, and refresh running sessions. Limited to 50 sessions per call. Sessions belonging to a frozen category are a parked bucket and are excluded from this operation.

**Example Request:**
```bash
curl -X POST -H "X-API-Key: your_key" \
  "https://your-domain.com/api/v1/sessions/refresh_all"
```

**Example Response:**
```json
{
  "message": "Refresh complete",
  "refreshed": 5,
  "restarted": 2,
  "continued": 3,
  "errors": 0
}
```

### Update MCP Servers

```
PATCH /api/v1/sessions/:id/mcp_servers
```

Replace the list of MCP servers for a session. Max 50 servers. Each name must exist in the catalog.

**Request Body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `mcp_servers` | array | Yes | Array of MCP server names |

**Example Request:**
```bash
curl -X PATCH -H "X-API-Key: your_key" \
  -H "Content-Type: application/json" \
  -d '{"mcp_servers": ["playwright-custom", "github"]}' \
  "https://your-domain.com/api/v1/sessions/1/mcp_servers"
```

### Update Catalog Skills

```
PATCH /api/v1/sessions/:id/catalog_skills
```

Replace the list of catalog skills for a session.

**Request Body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `catalog_skills` | array | Yes | Array of skill names |

### Update Catalog Hooks

```
PATCH /api/v1/sessions/:id/catalog_hooks
```

Replace the list of catalog hooks for a session.

**Request Body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `catalog_hooks` | array | Yes | Array of hook names |

### Update Catalog Plugins

```
PATCH /api/v1/sessions/:id/catalog_plugins
```

Replace the list of catalog plugins for a session.

**Request Body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `catalog_plugins` | array | Yes | Array of plugin IDs |

### Update Model

```
PATCH /api/v1/sessions/:id/model
```

Change the model used by the session (e.g., `opus`, `sonnet`, `haiku`).

The model must be valid for the session's `agent_runtime` (see [Create Session](#create-session) for runtime details). Submitting a model that is not in the runtime's catalog returns `422 Unprocessable Entity` with an `error` of `"Invalid model"` and a `message` listing the valid models for that runtime.

The valid model set is scoped to the runtime:

| Runtime | Valid models | Default |
|---------|--------------|---------|
| `claude_code` | `opus`, `sonnet`, `haiku` | `opus` |
| `codex` | `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.3-codex`, `gpt-5.2-codex` | `gpt-5.5` |

`gpt-5.5` requires an interactive ChatGPT login (no API-key support); `gpt-5.2-codex` is deprecated. `codex` models are selectable only once the Codex runtime is available on a session.

**Request Body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `model` | string | Yes | Model identifier — must be valid for the session's runtime |

**Example Request:**
```bash
curl -X PATCH -H "X-API-Key: your_key" \
  -H "Content-Type: application/json" \
  -d '{"model": "sonnet"}' \
  "https://your-domain.com/api/v1/sessions/1/model"
```

**Error Response (invalid model for runtime):**
```json
{
  "error": "Invalid model",
  "message": "model \"gpt-5\" is not valid for runtime claude_code. Valid models: opus, sonnet, haiku"
}
```

### Update Session Notes

```
PATCH /api/v1/sessions/:id/notes
```

Update the free-form notes attached to a session (max 50,000 chars). Pass an empty string to clear.

**Request Body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `session_notes` | string | Yes | Notes text |

**Example Request:**
```bash
curl -X PATCH -H "X-API-Key: your_key" \
  -H "Content-Type: application/json" \
  -d '{"session_notes": "Investigating the auth flow regression"}' \
  "https://your-domain.com/api/v1/sessions/1/notes"
```

### Toggle Favorite

```
POST /api/v1/sessions/:id/toggle_favorite
```

Toggle the favorited flag on a session. Favorited sessions sort to the top of the dashboard.

**Example Request:**
```bash
curl -X POST -H "X-API-Key: your_key" \
  "https://your-domain.com/api/v1/sessions/1/toggle_favorite"
```

**Example Response:**
```json
{
  "session": {"id": 1, "favorited": true},
  "favorited": true
}
```

### Set Session Category

```
PATCH /api/v1/sessions/:id/set_category
```

Assign the session to a category, or move it back to "Uncategorized". Pass the target `category_id`, or omit it / send a blank value to clear the category.

**Request Body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `category_id` | integer | No | Target category ID. Blank or omitted moves the session to Uncategorized. |

**Example Request:**
```bash
curl -X PATCH -H "X-API-Key: your_key" \
  -H "Content-Type: application/json" \
  -d '{"category_id": 3}' \
  "https://your-domain.com/api/v1/sessions/1/set_category"
```

**Example Response:**
```json
{
  "session": {
    "id": 1,
    "category_id": 3,
    "category": {"id": 3, "name": "Auth work", "position": 0, "is_frozen": false}
  },
  "message": "Session assigned to category"
}
```

Moving a session to Uncategorized (blank `category_id`) returns `"category_id": null`, `"category": null`, and the message `"Session moved to Uncategorized"`.

**Status Codes:**
- `200 OK` — category set or cleared
- `404 Not Found` — the supplied `category_id` does not match any category

### Get Plain-Text Transcript

```
GET /api/v1/sessions/:id/transcript
```

Returns a formatted, human-readable plain-text rendering of the session's transcript. Useful for reports, summaries, or feeding into other agents.

**Query Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `format` | string | Set to `"text"` to return `text/plain` instead of JSON-wrapped (default: JSON) |

**Example Request:**
```bash
curl -H "X-API-Key: your_key" \
  "https://your-domain.com/api/v1/sessions/1/transcript?format=text"
```

---

## Categories

Categories are organizational buckets used to group session cards on the dashboard. Each category has a `position` that controls its top-to-bottom order in the UI. A **frozen** category (`is_frozen: true`) is a parked bucket that is excluded from refresh-all and recovery. Sessions that belong to no category are considered "Uncategorized".

Deleting a category does not delete its sessions — they fall back to Uncategorized (their `category_id` is nullified).

### Category Object

| Field | Type | Description |
|-------|------|-------------|
| `id` | integer | Unique category ID |
| `name` | string | Category name (unique, case-insensitive, max 100 chars) |
| `description` | string | Optional description (max 1000 chars), used to guide auto-categorization of new sessions |
| `position` | integer | Sort order (ascending) in the dashboard |
| `is_frozen` | boolean | Whether the category is parked (excluded from refresh-all and recovery) |
| `session_count` | integer | Number of sessions currently assigned to this category |
| `created_at` | string | ISO 8601 creation timestamp |
| `updated_at` | string | ISO 8601 last update timestamp |

### List Categories

```
GET /api/v1/categories
```

Returns all categories ordered by `position` (ascending), each with its current `session_count`.

**Example Request:**
```bash
curl -H "X-API-Key: your_key" \
  "https://your-domain.com/api/v1/categories"
```

**Example Response:**
```json
{
  "categories": [
    {
      "id": 3,
      "name": "Auth work",
      "description": "Sessions touching authentication",
      "position": 0,
      "is_frozen": false,
      "session_count": 4,
      "created_at": "2025-01-15T14:30:00Z",
      "updated_at": "2025-01-15T14:30:00Z"
    }
  ]
}
```

### Create Category

```
POST /api/v1/categories
```

**Request Body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | Category name (unique, case-insensitive, max 100 chars). Surrounding whitespace is stripped. |
| `description` | string | No | Description (max 1000 chars). Blank is stored as null. |

New categories are appended to the end of the stack (highest `position`).

**Example Request:**
```bash
curl -X POST -H "X-API-Key: your_key" \
  -H "Content-Type: application/json" \
  -d '{"name": "Auth work", "description": "Sessions touching authentication"}' \
  "https://your-domain.com/api/v1/categories"
```

**Example Response (`201 Created`):**
```json
{
  "category": {
    "id": 3,
    "name": "Auth work",
    "description": "Sessions touching authentication",
    "position": 2,
    "is_frozen": false,
    "session_count": 0,
    "created_at": "2025-01-15T14:30:00Z",
    "updated_at": "2025-01-15T14:30:00Z"
  }
}
```

**Status Codes:**
- `201 Created` — category created
- `422 Unprocessable Entity` — validation failed (blank/duplicate/too-long name, etc.)

### Update Category

```
PATCH /api/v1/categories/:id
PUT   /api/v1/categories/:id
```

Update any subset of a category's name, description, and frozen state. Only the fields you send are changed — sending just `is_frozen` leaves the name and description untouched.

**Request Body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | No | New name (unique, case-insensitive, max 100 chars). |
| `description` | string | No | New description (max 1000 chars). Blank clears it (stored as null). |
| `is_frozen` | boolean | No | Freeze (`true`) or unfreeze (`false`) the category. |

**Example Request:**
```bash
curl -X PATCH -H "X-API-Key: your_key" \
  -H "Content-Type: application/json" \
  -d '{"is_frozen": true}' \
  "https://your-domain.com/api/v1/categories/3"
```

**Example Response (`200 OK`):**
```json
{
  "category": {
    "id": 3,
    "name": "Auth work",
    "description": "Sessions touching authentication",
    "position": 0,
    "is_frozen": true,
    "session_count": 4,
    "created_at": "2025-01-15T14:30:00Z",
    "updated_at": "2025-01-15T14:35:00Z"
  }
}
```

**Status Codes:**
- `200 OK` — category updated
- `404 Not Found` — no category with that ID
- `422 Unprocessable Entity` — validation failed

### Delete Category

```
DELETE /api/v1/categories/:id
```

Delete a category. Its sessions fall back to Uncategorized (their `category_id` is nullified).

**Example Request:**
```bash
curl -X DELETE -H "X-API-Key: your_key" \
  "https://your-domain.com/api/v1/categories/3"
```

**Status Codes:**
- `204 No Content` — category deleted
- `404 Not Found` — no category with that ID

### Reorder Categories

```
POST /api/v1/categories/reorder
```

Persist a new top-to-bottom ordering of the category stack. The `position` of each listed category is set to its index in the array. Categories omitted from the list keep their existing position.

The "Uncategorized" section is part of the same reorderable stack. Include the string sentinel `"uncategorized"` in the array to position it; its slot is stored separately (on the global app setting) and so it does not appear in the returned category list. Zero/blank ids are ignored.

**Request Body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `ids` | array | Yes | Ordered array of category IDs (top to bottom). May include the string `"uncategorized"` to position the Uncategorized section. |

**Example Request:**
```bash
curl -X POST -H "X-API-Key: your_key" \
  -H "Content-Type: application/json" \
  -d '{"ids": [5, "uncategorized", 3, 8]}' \
  "https://your-domain.com/api/v1/categories/reorder"
```

**Example Response (`200 OK`):**

Returns the full category list in its new order (same shape as List Categories).
```json
{
  "categories": [
    {"id": 5, "name": "Inbox", "position": 0, "is_frozen": false, "session_count": 1, "description": null, "created_at": "2025-01-15T14:30:00Z", "updated_at": "2025-01-15T14:35:00Z"},
    {"id": 3, "name": "Auth work", "position": 1, "is_frozen": false, "session_count": 4, "description": null, "created_at": "2025-01-15T14:30:00Z", "updated_at": "2025-01-15T14:35:00Z"},
    {"id": 8, "name": "Backlog", "position": 2, "is_frozen": true, "session_count": 0, "description": null, "created_at": "2025-01-15T14:30:00Z", "updated_at": "2025-01-15T14:35:00Z"}
  ]
}
```

---

## Logs

Logs record events during session execution. All log operations are scoped to a specific session.

### Log Object

| Field | Type | Description |
|-------|------|-------------|
| `id` | integer | Unique log ID |
| `session_id` | integer | Parent session ID |
| `content` | string | Log message |
| `level` | string | Log level: `info`, `error`, `debug`, `warning`, `verbose` |
| `created_at` | string | ISO 8601 creation timestamp |
| `updated_at` | string | ISO 8601 last update timestamp |

### List Logs

```
GET /api/v1/sessions/:session_id/logs
```

**Query Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `level` | string | Filter by log level |
| `page` | integer | Page number |
| `per_page` | integer | Results per page (max: 100) |

**Example Request:**
```bash
curl -H "X-API-Key: your_key" \
  "https://your-domain.com/api/v1/sessions/1/logs?level=error"
```

**Example Response:**
```json
{
  "logs": [
    {
      "id": 1,
      "session_id": 1,
      "content": "Agent encountered an error: file not found",
      "level": "error",
      "created_at": "2025-01-15T14:32:00Z",
      "updated_at": "2025-01-15T14:32:00Z"
    }
  ],
  "pagination": {
    "page": 1,
    "per_page": 25,
    "total_count": 1,
    "total_pages": 1
  }
}
```

### Get Log

```
GET /api/v1/sessions/:session_id/logs/:id
```

### Create Log

```
POST /api/v1/sessions/:session_id/logs
```

**Request Body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `content` | string | Yes | Log message |
| `level` | string | Yes | Log level: `info`, `error`, `debug`, `warning`, `verbose` |

**Example Request:**
```bash
curl -X POST -H "X-API-Key: your_key" \
  -H "Content-Type: application/json" \
  -d '{"content": "External system notification", "level": "info"}' \
  "https://your-domain.com/api/v1/sessions/1/logs"
```

**Status Code:** `201 Created`

### Update Log

```
PATCH /api/v1/sessions/:session_id/logs/:id
```

**Updatable Fields:** `content`, `level`.

### Delete Log

```
DELETE /api/v1/sessions/:session_id/logs/:id
```

**Status Code:** `204 No Content`

---

## Enqueued Messages

Enqueued messages are follow-up prompts queued for delivery to a running session. They are processed sequentially when the agent finishes its current task.

### Enqueued Message Object

| Field | Type | Description |
|-------|------|-------------|
| `id` | integer | Unique message ID |
| `session_id` | integer | Parent session ID |
| `content` | string | Message text |
| `goal` | string | Optional goal override |
| `position` | integer | 1-based queue position |
| `status` | string | `pending`, `processing`, or `sent` |
| `created_at` | string | ISO 8601 creation timestamp |
| `updated_at` | string | ISO 8601 last update timestamp |

### List Enqueued Messages

```
GET /api/v1/sessions/:session_id/enqueued_messages
```

**Query Parameters:** `status`, `page`, `per_page`.

### Get Enqueued Message

```
GET /api/v1/sessions/:session_id/enqueued_messages/:id
```

### Create Enqueued Message

```
POST /api/v1/sessions/:session_id/enqueued_messages
```

**Request Body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `content` | string | Yes | Message text (max 500,000 chars) |
| `goal` | string | No | Optional goal override |

**Status Code:** `201 Created`

### Update Enqueued Message

```
PATCH /api/v1/sessions/:session_id/enqueued_messages/:id
```

**Updatable Fields:** `content`, `goal`.

### Delete Enqueued Message

```
DELETE /api/v1/sessions/:session_id/enqueued_messages/:id
```

Removes the message and re-numbers remaining positions.

**Status Code:** `204 No Content`

### Reorder Enqueued Message

```
PATCH /api/v1/sessions/:session_id/enqueued_messages/:id/reorder
```

**Request Body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `position` | integer | Yes | New position (>= 1) |

### Interrupt with Enqueued Message

```
POST /api/v1/sessions/:session_id/enqueued_messages/:id/interrupt
```

Send this enqueued message immediately, interrupting the current session. If the session is running, it is paused first.

---

## Subagent Transcripts

Subagent transcripts store the conversation history of nested agents spawned via the Task tool during session execution.

### Subagent Transcript Object

| Field | Type | Description |
|-------|------|-------------|
| `id` | integer | Unique transcript ID |
| `session_id` | integer | Parent session ID |
| `agent_id` | string | Unique identifier for the subagent |
| `tool_use_id` | string | ID of the parent Task tool call |
| `transcript` | string | JSONL transcript content (when requested) |
| `filename` | string | Original transcript filename |
| `message_count` | integer | Number of messages in transcript |
| `subagent_type` | string | Type of subagent (e.g., `explore`, `plan`) |
| `description` | string | Description of the subagent task |
| `status` | string | Status: `running`, `completed`, `failed` |
| `duration_ms` | integer | Execution duration in milliseconds |
| `total_tokens` | integer | Total tokens used |
| `tool_use_count` | integer | Number of tool uses |
| `formatted_duration` | string | Human-readable duration (e.g., `2m 35s`) |
| `formatted_tokens` | string | Human-readable token count (e.g., `3.5k`) |
| `display_label` | string | Display label for UI |
| `created_at` | string | ISO 8601 creation timestamp |
| `updated_at` | string | ISO 8601 last update timestamp |

### List Subagent Transcripts

```
GET /api/v1/sessions/:session_id/subagent_transcripts
```

**Query Parameters:** `status`, `subagent_type`, `page`, `per_page`.

### Get Subagent Transcript

```
GET /api/v1/sessions/:session_id/subagent_transcripts/:id
```

**Query Parameters:** `include_transcript` (boolean) — include the full JSONL transcript.

### Create / Update / Delete

Standard CRUD: `POST`, `PATCH`, `DELETE` at the same paths. See controller for the full list of writable fields.

---

## Elicitations

Approve or decline pending MCP elicitation (action-approval) requests.

In every path below, `:id` is the elicitation's `request_id` (the MCP-facing identifier), **not** the database primary key.

### Respond to an Elicitation

```
PATCH /api/v1/elicitations/:id/respond
```

Programmatically resolve a pending elicitation. This is the authenticated counterpart to the human web UI — it lets a script, agent, or tool accept or decline an approval request. Resolving the elicitation unblocks the owning session (flips it from `needs_input` back to `running`).

**Body Parameters:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `action_type` | string | Yes | One of `accept` or `decline`. |
| `content` | object | No | Optional JSON object with the form response to persist (typically supplied when accepting). |

**Response:** `200 OK` with the poll response.

| Field | Type | Description |
|-------|------|-------------|
| `action` | string | The resolved action (`accept` or `decline`). |
| `content` | object | The persisted response content (may be `null`). |
| `_meta` | object | Carries `com.pulsemcp/request-id` and `com.pulsemcp/responded-at`. |

**Errors:**

- `404 Not Found` — no elicitation matches the `request_id`.
- `422 Unprocessable Entity` — the elicitation has already been resolved, or `action_type` is invalid.

**Example Request:**
```bash
curl -X PATCH -H "X-API-Key: your_key" -H "Content-Type: application/json" \
  -d '{"action_type":"accept","content":{"approved":true}}' \
  "https://your-domain.com/api/v1/elicitations/req-abc-123/respond"
```

> **Note:** `POST /api/v1/elicitations` and `GET /api/v1/elicitations/:id` also exist but are part of the internal MCP fallback protocol (called by MCP servers, unauthenticated) and are not intended for general API consumers.

---

## Configuration

Read-only endpoints exposing catalog metadata.

### Get All Configs

```
GET /api/v1/configs
```

Returns all static configuration data in a single call.

**Response:**

| Field | Type | Description |
|-------|------|-------------|
| `mcp_servers` | array | Available MCP servers (`name`, `title`, `description`) |
| `agent_roots` | array | Preconfigured agent root catalog entries (with `name`, `url`, `default_branch`, `subdirectory`, `default_mcp_servers`, `default_skills`, `default_hooks`, `default_plugins`, `default_model`) |
| `goals` | array | Available session goals |

**Example Request:**
```bash
curl -H "X-API-Key: your_key" \
  "https://your-domain.com/api/v1/configs"
```

### List MCP Servers

```
GET /api/v1/mcp_servers
```

Returns the available MCP servers as an array.

### List Skills

```
GET /api/v1/skills
```

Returns the available catalog skills.

---

## Rate Limiting

Currently, the API does not implement rate limiting. However, consider implementing client-side rate limiting to avoid overwhelming the server.

---

## Webhooks

Webhook support is not currently available. For real-time updates, consider polling the session status endpoint or using the web interface which supports WebSocket-based Turbo Streams.

---

## SDK Examples

### Python

```python
import requests

API_KEY = "your_api_key"
BASE_URL = "https://your-domain.com/api/v1"

headers = {"X-API-Key": API_KEY}

# Create a session
response = requests.post(
    f"{BASE_URL}/sessions",
    headers=headers,
    json={
        "agent_runtime": "claude_code",
        "prompt": "Fix the authentication bug",
        "git_root": "https://github.com/example/repo.git",
        "branch": "main"
    }
)
session = response.json()["session"]
print(f"Created session {session['id']}")

# Poll for completion
import time
while True:
    response = requests.get(f"{BASE_URL}/sessions/{session['id']}", headers=headers)
    status = response.json()["session"]["status"]
    print(f"Status: {status}")

    if status in ["needs_input", "failed", "archived"]:
        break
    time.sleep(5)

# Get logs
response = requests.get(f"{BASE_URL}/sessions/{session['id']}/logs", headers=headers)
for log in response.json()["logs"]:
    print(f"[{log['level']}] {log['content']}")
```

### JavaScript/Node.js

```javascript
const API_KEY = "your_api_key";
const BASE_URL = "https://your-domain.com/api/v1";

const headers = {
  "X-API-Key": API_KEY,
  "Content-Type": "application/json"
};

// Create a session
async function createSession() {
  const response = await fetch(`${BASE_URL}/sessions`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      agent_runtime: "claude_code",
      prompt: "Add unit tests for the User model",
      git_root: "https://github.com/example/repo.git",
      branch: "main"
    })
  });

  const { session } = await response.json();
  console.log(`Created session ${session.id}`);
  return session;
}

// Send follow-up prompt
async function sendFollowUp(sessionId, prompt) {
  const response = await fetch(`${BASE_URL}/sessions/${sessionId}/follow_up`, {
    method: "POST",
    headers,
    body: JSON.stringify({ prompt })
  });

  return response.json();
}
```

### cURL

```bash
# Set your API key
API_KEY="your_api_key"
BASE_URL="https://your-domain.com/api/v1"

# Create a session
curl -X POST "$BASE_URL/sessions" \
  -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "agent_runtime": "claude_code",
    "prompt": "Refactor the database queries",
    "git_root": "https://github.com/example/repo.git"
  }'

# List all running sessions
curl "$BASE_URL/sessions?status=running" \
  -H "X-API-Key: $API_KEY"

# Archive a session
curl -X POST "$BASE_URL/sessions/1/archive" \
  -H "X-API-Key: $API_KEY"
```

---

## Changelog

### v1 (Current)

- Full CRUD for sessions, logs, enqueued messages, and subagent transcripts
- Session lifecycle management (archive/unarchive, pause, sleep, resume, restart, fork, refresh, follow_up, force_immediate)
- Catalog updates (mcp_servers, skills, hooks, plugins, model) and session notes / favorites
- Read-only catalog endpoints (configs, mcp_servers, skills)
- Search + dependency graph + bulk archive + bulk refresh
- API key authentication, pagination, slug-based lookups
