# MCP Configuration

This document describes the `mcp.json` configuration format for defining MCP (Model Context Protocol) servers. This format is inspired by Claude Code's `mcpServers` configuration but tailored for our use case.

## Overview

An `mcp.json` file defines a collection of MCP servers that an MCP client application can connect to. Each server is identified by a unique name key and configured with transport-specific settings.

## Relationship to server.json

The MCP ecosystem has two related but distinct configuration formats:

| Format | Purpose | Configurability |
|--------|---------|-----------------|
| `server.json` | Server package specification for registries | Highly configurable with variables, templates, and user-adjustable parameters |
| `mcp.json` | Client-side server configuration | Fully resolved; only auth secrets are interpolated |

**server.json** (defined by the [MCP Registry](https://github.com/modelcontextprotocol/registry)) is a package specification format used to describe MCP server packages for discovery and distribution. It supports:
- Multiple package types (npm, PyPI, Docker, etc.)
- Metadata including version, description, and icons
- Runtime hints (npx, docker, python, etc.)
- Environment variable specifications with `isRequired` and `isSecret` flags

**mcp.json** represents a fully-formed, opinionated configuration for a specific MCP client. Each entry in an `mcp.json` is what you get *after* resolving a `server.json` template with concrete values. The only remaining configurability is authentication secrets via environment variable interpolation.

Think of it this way:
- `server.json` = "Here's how this server *can* be configured"
- `mcp.json` = "Here's exactly how this client *will* connect to its servers"

## Schema

The formal JSON schema is available at [`mcp.schema.json`](./mcp.schema.json).

## File Structure

```json
{
  "server-name": {
    "title": "Human-Readable Name",
    "type": "stdio",
    "command": "executable",
    "args": ["arg1", "arg2"],
    "env": {
      "VAR_NAME": "value"
    }
  }
}
```

The root object is a map of server names to server configurations. Server names must be alphanumeric with hyphens or underscores allowed (matching the pattern `^[a-zA-Z0-9_-]+$`).

## Server Configuration

### Common Properties

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `title` | string | No | Human-readable display name (1-100 chars) |
| `type` | string | Yes | Transport type: `stdio`, `sse`, or `streamable-http` |

### Transport Types

#### stdio (Local Process)

For servers that run as local processes and communicate via stdin/stdout.

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `command` | string | Yes | Executable command to run |
| `args` | string[] | No | Command-line arguments |
| `env` | object | No | Environment variables for the process |

Example:

```json
{
  "filesystem": {
    "title": "Filesystem Server",
    "type": "stdio",
    "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/allowed/directory"],
    "env": {
      "NODE_ENV": "production"
    }
  }
}
```

#### sse (Server-Sent Events)

For remote servers using the SSE transport protocol.

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `url` | string | Yes | Server endpoint URL |
| `headers` | object | No | HTTP headers for requests |

Example:

```json
{
  "remote-tools": {
    "title": "Remote Tools Server",
    "type": "sse",
    "url": "https://mcp.example.com/sse",
    "headers": {
      "Authorization": "Bearer ${API_TOKEN}"
    }
  }
}
```

#### streamable-http

For remote servers using HTTP streaming.

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `url` | string | Yes | Server endpoint URL |
| `headers` | object | No | HTTP headers for requests |

Example:

```json
{
  "api-server": {
    "title": "API Server",
    "type": "streamable-http",
    "url": "https://api.example.com/mcp",
    "headers": {
      "X-API-Key": "${API_KEY}"
    }
  }
}
```

## Environment Variable Interpolation

String values in `mcp.json` support environment variable interpolation for injecting secrets at runtime.

### Syntax

| Pattern | Description |
|---------|-------------|
| `${VAR}` | Replaced with the value of environment variable `VAR` |
| `${VAR:-default}` | Uses `VAR` if set, otherwise falls back to `default` |

### Supported Fields

Interpolation is supported in:
- `command`
- `args` (each element)
- `env` (values only)
- `url`
- `headers` (values only)

### Purpose and Scope

**Important:** Environment variable interpolation is primarily intended for authentication secrets. This includes:

- API keys (e.g., `${OPENAI_API_KEY}`)
- Bearer tokens (e.g., `Bearer ${AUTH_TOKEN}`)
- Other credentials required for server authentication

While interpolation technically works in other fields (like `url` or `command`), the `mcp.json` file is meant to be a fully-formed configuration. Using interpolation for non-secret values is discouraged as it undermines its purpose as a concrete client configuration.

### Examples

**API Key in environment:**

```json
{
  "github": {
    "title": "GitHub Tools",
    "type": "stdio",
    "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-github"],
    "env": {
      "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}"
    }
  }
}
```

**Bearer token in header:**

```json
{
  "authenticated-api": {
    "title": "Authenticated API",
    "type": "streamable-http",
    "url": "https://api.example.com/mcp",
    "headers": {
      "Authorization": "Bearer ${API_TOKEN}"
    }
  }
}
```

### OAuth-Based Servers

Servers using OAuth authentication require no special configuration in `mcp.json`. MCP clients discover OAuth endpoints automatically via [RFC 8414](https://datatracker.ietf.org/doc/html/rfc8414) (OAuth Authorization Server Metadata) or [RFC 9728](https://datatracker.ietf.org/doc/html/rfc9728) (OAuth Protected Resource Metadata) well-known endpoints:

```json
{
  "oauth-server": {
    "title": "OAuth-Protected Server",
    "type": "streamable-http",
    "url": "https://oauth.example.com/mcp"
  }
}
```

The OAuth flow is managed by the MCP client application, not through static configuration values.

## Complete Example

```json
{
  "filesystem": {
    "title": "Filesystem Access",
    "type": "stdio",
    "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/user/projects"]
  },
  "github": {
    "title": "GitHub Integration",
    "type": "stdio",
    "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-github"],
    "env": {
      "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}"
    }
  },
  "internal-api": {
    "title": "Internal API",
    "type": "streamable-http",
    "url": "https://internal.example.com/mcp",
    "headers": {
      "Authorization": "Bearer ${INTERNAL_API_KEY}",
      "X-Team-ID": "engineering"
    }
  }
}
```

## Validation

Validate your `mcp.json` against the schema:

```bash
# Using ajv-cli (Node.js)
npm install -g ajv-cli
npx ajv-cli validate -s mcp.schema.json -d mcp.json

# Using check-jsonschema (Python)
pip install check-jsonschema
check-jsonschema --schemafile mcp.schema.json mcp.json
```

## Error Handling

- If a required environment variable (without a default) is not set, the MCP client should fail with a clear error message indicating which variable is missing.
- Invalid transport type configurations (e.g., `url` with `stdio`) should be rejected at parse time.

## Usage in This Project

The `config/mcp.json` file contains the catalog of available MCP servers. The `ServersConfig` service parses this file and provides server information to the UI. At runtime, `AirPrepareService` shells out to the AIR CLI to generate `.mcp.json` and then post-processes it to resolve environment variable interpolations.
