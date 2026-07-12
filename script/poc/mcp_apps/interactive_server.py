#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "mcp>=1.26.0",
#     "uvicorn>=0.34.0",
#     "starlette>=0.46.0",
# ]
# ///
"""
Interactive MCP App demo server (SEP-1865 / io.modelcontextprotocol/ui).

Exercises the *interactive* surface of MCP Apps so we can prove it works when
Zimmer is the host:
  - callServerTool  -> tools/call proxied by the host to this server (View <-> Server)
  - sendMessage     -> ui/message routed by the host into the agent conversation (View -> Agent)
  - sendLog         -> notifications/message

Tools:
  - open_panel  (model+app): declares the ui:// view, returns an initial payload.
  - get_server_time (app):   returns the current server time — the View calls it.
  - roll_dice   (app):       returns a random 1-6 — the View calls it.
"""
import os
import sys
import time
import random

import uvicorn
from mcp.server.fastmcp import FastMCP
from starlette.middleware.cors import CORSMiddleware

VIEW_URI = "ui://interactive-demo/panel.html"
HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "3002"))

mcp = FastMCP("Interactive Demo Server", stateless_http=True, host=HOST, port=PORT)


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

    const app = new App({ name: "Interactive Demo View", version: "1.0.0" });

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
        app = mcp.streamable_http_app()
        app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"],
                           allow_headers=["*"], expose_headers=["*"])
        print(f"Interactive Demo Server on http://{HOST}:{PORT}/mcp")
        uvicorn.run(app, host=HOST, port=PORT)
