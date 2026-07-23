# MCP Apps spike — surfacing `ui://` fragments in the session detail UI

A proof-of-concept exploring: **can Zimmer render interactive
[MCP Apps](https://github.com/modelcontextprotocol/ext-apps) UI fragments
(SEP-1865 / `io.modelcontextprotocol/ui`) inside its own session detail page,
given that the coding agents it orchestrates run *headlessly*?**

Answer: **yes** — not at the headless-agent layer, but by making **Zimmer's web
app its own MCP host**. Zimmer connects to an app-capable MCP server, calls a
tool, reads the `ui://` HTML fragment the tool declares, and renders it in a
sandboxed iframe, brokering the MCP-Apps `postMessage` protocol from the browser.

## Pieces

| File | Role |
| --- | --- |
| `fetch_app_fragment.mjs` | Dependency-free Node MCP client (Streamable HTTP). Zimmer's host **data plane**: `initialize` → `tools/list` → `tools/call` → `resources/read`, prints `{ serverInfo, tool, input, toolResult, ui:{ html, csp } }` as JSON. |
| `interactive_server.py` | Self-contained (uv, no build) MCP App server for the **interactivity** demo: `open_panel` declares the view; `get_server_time` / `roll_dice` are app-callable tools the View calls back through the host. |
| `app/services/mcp_app_preview_service.rb` | Rails wrapper that shells out to the bridge. Gated by `ENV["ZIMMER_MCP_APPS_POC"]`. |
| `app/javascript/controllers/mcp_app_host_controller.js` | The host **control plane** in the browser: renders the fragment in a sandboxed iframe and answers its `ui/initialize` handshake, then pushes `ui/notifications/tool-input` + `ui/notifications/tool-result`. |
| `app/views/sessions/_mcp_app_panel.html.erb` | The panel on the session detail page. |

## Run it locally

1. Start an app-capable MCP server. The spike uses the ext-apps QR example:

   ```bash
   git clone https://github.com/modelcontextprotocol/ext-apps.git
   cd ext-apps/examples/qr-server
   PORT=3001 uv run server.py        # → http://127.0.0.1:3001/mcp
   ```

2. Boot Zimmer with the flag on:

   ```bash
   ZIMMER_MCP_APPS_POC=1 ZIMMER_MCP_APPS_POC_URL=http://127.0.0.1:3001/mcp bin/dev
   ```

3. Open any session (`/sessions/:id`). The panel renders above the transcript,
   showing the QR fragment (which encodes that session's own URL). Append
   `?mcp_app=off` to skip the fetch for a page.

### Interactivity demo

```bash
# 1. run the interactive server (app-callable tools + a view that calls them)
PORT=3002 uv run script/poc/mcp_apps/interactive_server.py

# 2. point Zimmer at it
ZIMMER_MCP_APPS_POC=1 \
  ZIMMER_MCP_APPS_POC_URL=http://127.0.0.1:3002/mcp \
  ZIMMER_MCP_APPS_POC_TOOL=open_panel \
  ZIMMER_MCP_APPS_POC_ARGS='{"note":"hi"}' \
  bin/dev
```

Open a session: **Refresh time** / **Roll dice** round-trip `tools/call` through
Zimmer to the server (View → Server); **Send roll to agent** fires `ui/message`,
which the broker drops into the session's follow-up prompt box (View → Agent).

Test the bridge alone:

```bash
node script/poc/mcp_apps/fetch_app_fragment.mjs \
  --url http://127.0.0.1:3001/mcp --tool generate_qr \
  --args '{"text":"https://example.com"}' | head -c 400
```

## Scope / what this is NOT

- **Spike quality, flag-gated.** The preview is fetched **synchronously** during
  `SessionsController#show` — fine behind a flag, wrong for production (should be
  async / on-demand / cached).
- **Single-iframe sandbox.** The spec's full security model wraps the View in a
  **separate-origin** sandbox-proxy iframe with header-based CSP. This spike
  renders directly into one `sandbox="allow-scripts"` (opaque-origin) iframe,
  which is enough to prove rendering + protocol but is not the hardened form.
- It does **not** yet surface fragments for tool calls the *headless agent*
  makes — it drives the tool call itself. See the docs page for that roadmap.

See `docs/src/content/docs/extend/mcp-apps-spike.md`.
