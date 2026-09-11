# `scripts/mcp_apps_demo/` — an app-capable MCP server for trying MCP Apps locally

A development fixture for [MCP Apps](../../docs/src/content/docs/extend/mcp-apps.md) support. Nothing
in the deployment depends on it: it is not in the AIR catalog, it is not started by anything, and
production never sees it.

It exists because MCP Apps support cannot be seen working without a server that actually ships a
`ui://` view, and there is no such server in Zimmer's catalog.

## Run it

```bash
scripts/mcp_apps_demo/server.py           # http://127.0.0.1:3002/mcp
PORT=4002 scripts/mcp_apps_demo/server.py # somewhere else
```

It is a [uv](https://docs.astral.sh/uv/) single-file script — the dependencies are in its header and
uv fetches them on first run.

## Point a local Zimmer at it

MCP servers come from the AIR catalog, so the demo needs a catalog entry. **Add it to your working
copy of `mcp.json` and do not commit it** — a localhost entry in the shipped catalog would be a dead
server on every other deployment:

```json
  "mcp-apps-demo": {
    "title": "MCP Apps demo",
    "description": "Local app-capable MCP server (scripts/mcp_apps_demo).",
    "type": "streamable-http",
    "url": "http://127.0.0.1:3002/mcp"
  },
```

Then:

1. `bin/rails runner 'AirCatalogService.reload!'` (or restart the app).
2. **Settings → MCP Apps**: tick **Render MCP App views**, tick **MCP Apps demo**, save.
3. Give a session `mcp-apps-demo` in its MCP servers, and let the agent call
   `mcp__mcp-apps-demo__open_panel`.

The panel appears in the transcript under that tool call.

## What it exercises

| Tool | `_meta.ui` | What it proves |
| --- | --- | --- |
| `open_panel` | `resourceUri` | The transcript trigger, and that a model-only tool is **not** callable from the view |
| `get_server_time` | `visibility: ["app"]` | View→Server `tools/call`, proxied by Rails |
| `roll_dice` | `visibility: ["app"]` | The same, plus the value the view then sends to the agent |

The view resource declares `csp: { resourceDomains: ["https://unpkg.com"] }` and loads the MCP Apps
SDK from there, so it renders at all only if Zimmer honours the declared domain — and its
`connect-src` stays `'none'`, because it declared no connect domains.

The **💬 Send roll to agent** button sends `ui/message`, which Zimmer turns into a real agent turn on
the session the panel is rendered in.
