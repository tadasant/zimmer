#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     # Pinned below 2.x: FastMCP was renamed to MCPServer there and the
#     # decorator API changed, so an unpinned run of this file breaks on import.
#     "mcp>=1.26.0,<2",
#     "uvicorn>=0.34.0",
#     "starlette>=0.46.0",
# ]
# ///
"""
An app-capable MCP server, for exercising Zimmer's MCP Apps support locally.

It is a development fixture, not part of the deployment: nothing in the app
depends on it, and it is not in the AIR catalog. See README.md in this directory
for how to point a local Zimmer at it.

It exercises every leg of the protocol Zimmer implements:
  - a ui:// view resource, declaring its own CSP (it loads the MCP Apps SDK from
    unpkg, so `resourceDomains` has to be honoured for the view to run at all)
  - callServerTool  -> tools/call proxied server-side by Zimmer (View <-> Server)
  - sendMessage     -> ui/message routed into a real agent turn (View -> Agent)
  - sendLog         -> notifications/message

Tools:
  - open_panel      (model): declares the ui:// view, returns an initial payload.
  - get_server_time (app):   returns the current server time — the View calls it.
  - roll_dice       (app):   returns a random 1-6 — the View calls it.

`get_server_time` and `roll_dice` carry `visibility: ["app"]`, which is what
makes them reachable through Zimmer's proxy; `open_panel` does not, which is why
the view cannot re-invoke the call that created it.
"""
import os
import sys
import time
import random

import uvicorn
from mcp.server.fastmcp import FastMCP

VIEW_URI = "ui://mcp-apps-demo/panel.html"
HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "3002"))

mcp = FastMCP("MCP Apps Demo Server", stateless_http=True, host=HOST, port=PORT)


def _now() -> str:
    return time.strftime("%H:%M:%S", time.localtime())


EMBEDDED_VIEW_HTML = """<!DOCTYPE html>
<html>
<head>
  <meta name="color-scheme" content="light dark">
  <style>
    html, body { margin: 0; padding: 0; background: transparent; font-family: ui-sans-serif, system-ui, sans-serif; }
    .card { padding: 18px; width: 380px; box-sizing: border-box; }
    .readout { display:flex; gap:14px; margin-bottom:14px; }
    .stat { flex:1; background:#f3f4f6; border-radius:10px; padding:12px 14px; }
    .stat .k { font-size:11px; text-transform:uppercase; letter-spacing:.04em; color:#6b7280; }
    .stat .v { font-size:22px; font-weight:700; color:#111827; font-variant-numeric: tabular-nums; }
    .row { display:flex; gap:8px; flex-wrap:wrap; margin-bottom:12px; }
    button { border:0; border-radius:8px; padding:9px 12px; font-size:13px; font-weight:600; cursor:pointer; }
    .primary { background:#4f46e5; color:#fff; }
    .neutral { background:#e5e7eb; color:#111827; }
    .send { background:#059669; color:#fff; }
    .log { font-family: ui-monospace, monospace; font-size:11px; color:#4b5563; background:#f9fafb; border:1px solid #eef2f7; border-radius:8px; padding:8px 10px; height:96px; overflow:auto; white-space:pre-wrap; }
    .pulse { animation: p .5s ease; }
    @keyframes p { 0%{background:#c7d2fe} 100%{background:#f3f4f6} }
  </style>
</head>
<body>
  <div class="card">
    <div class="readout">
      <div class="stat"><div class="k">Server time</div><div class="v" id="time">—</div></div>
      <div class="stat"><div class="k">Last roll</div><div class="v" id="dice">—</div></div>
    </div>
    <div class="row">
      <button class="primary" id="refresh">🔄 Refresh time</button>
      <button class="neutral" id="roll">🎲 Roll dice</button>
      <button class="send" id="send">💬 Send roll to agent</button>
    </div>
    <div class="log" id="log"></div>
  </div>
  <script type="module">
    import { App } from "https://unpkg.com/@modelcontextprotocol/ext-apps@0.4.0/app-with-deps";

    const $ = (id) => document.getElementById(id);
    const log = (m) => { const el = $('log'); el.textContent += m + "\\n"; el.scrollTop = el.scrollHeight; };
    const pulse = (id) => { const el = $(id); el.classList.remove('pulse'); void el.offsetWidth; el.classList.add('pulse'); };

    const app = new App({ name: "MCP Apps Demo View", version: "1.0.0" });

    // FastMCP returns the payload as JSON text in content[0]; some hosts also
    // populate structuredContent. Read whichever is present.
    const payload = (r) => {
      if (r?.structuredContent) return r.structuredContent;
      try { return JSON.parse(r?.content?.[0]?.text ?? "{}"); } catch { return {}; }
    };

    // Initial payload delivered with the tool result that opened the panel.
    app.ontoolresult = (r) => {
      const sc = payload(r);
      if (sc?.time) { $('time').textContent = sc.time; pulse('time'); }
      log("← tool-result (initial): " + JSON.stringify(sc || {}));
    };

    await app.connect();
    log("✓ connected to host: " + (app.getHostContext()?.userAgent || "host"));

    // View -> Server (host proxies tools/call to the MCP server)
    $('refresh').addEventListener('click', async () => {
      log("→ callServerTool get_server_time …");
      const r = await app.callServerTool({ name: "get_server_time", arguments: {} });
      const t = payload(r).time ?? "?";
      $('time').textContent = t; pulse('time');
      log("← get_server_time: " + t);
    });

    $('roll').addEventListener('click', async () => {
      log("→ callServerTool roll_dice …");
      const r = await app.callServerTool({ name: "roll_dice", arguments: {} });
      const n = payload(r).value ?? "?";
      $('dice').textContent = n; pulse('dice');
      log("← roll_dice: " + n);
    });

    // View -> Agent (host routes ui/message into the conversation / follow-up prompt)
    $('send').addEventListener('click', async () => {
      const n = $('dice').textContent;
      const text = n === "—"
        ? "Roll the dice for me (from the MCP App panel)."
        : `The MCP App panel rolled a ${n}. Please note it and roll again if it's below 4.`;
      log("→ sendMessage (to agent): " + text);
      try {
        await app.sendMessage({ role: "user", content: [{ type: "text", text }] });
        log("✓ host accepted the message");
      } catch (e) { log("✗ " + e.message); }
    });
  </script>
</body>
</html>"""


@mcp.tool(meta={"ui": {"resourceUri": VIEW_URI}, "ui/resourceUri": VIEW_URI})
def open_panel(note: str = "") -> dict:
    """Open the interactive demo panel."""
    return {"time": _now(), "note": note}


@mcp.tool(meta={"ui": {"visibility": ["app"]}})
def get_server_time() -> dict:
    """Return the current server time (called by the View)."""
    return {"time": _now()}


@mcp.tool(meta={"ui": {"visibility": ["app"]}})
def roll_dice() -> dict:
    """Roll a six-sided die (called by the View)."""
    return {"value": random.randint(1, 6)}


@mcp.resource(VIEW_URI, mime_type="text/html;profile=mcp-app",
              meta={"ui": {"csp": {"resourceDomains": ["https://unpkg.com"]}}})
def view() -> str:
    return EMBEDDED_VIEW_HTML


if __name__ == "__main__":
    if "--stdio" in sys.argv:
        mcp.run(transport="stdio")
    else:
        # No CORS middleware. Zimmer proxies the view's requests server-side, so
        # the browser never calls this server directly — if it works only with
        # `Access-Control-Allow-Origin: *`, something is reaching it the wrong way.
        app = mcp.streamable_http_app()
        print(f"MCP Apps demo server on http://{HOST}:{PORT}/mcp")
        uvicorn.run(app, host=HOST, port=PORT)
