#!/usr/bin/env node
// MCP Apps spike — dependency-free MCP client ("host" side, data plane).
//
// Zimmer acts as its OWN MCP host/client: it connects to an app-capable MCP
// server (one that implements the io.modelcontextprotocol/ui extension,
// SEP-1865), calls a tool, and reads the `ui://` UI resource the tool declares.
// It prints a single JSON object to stdout:
//
//   { serverInfo, tool, toolResult, ui: { uri, mimeType, html, csp, permissions } }
//
// The browser-side host broker (mcp_app_host_controller.js) then renders
// `ui.html` in a sandboxed iframe and feeds it `toolResult` over the
// MCP-Apps postMessage protocol.
//
// This speaks Streamable HTTP MCP with plain `fetch` + minimal SSE parsing so
// it needs no npm dependencies. Node 18+ (global fetch). Usage:
//
//   node fetch_app_fragment.mjs --url http://127.0.0.1:3001/mcp \
//     --tool generate_qr --args '{"text":"https://example.com"}'

const RESOURCE_MIME_TYPE = "text/html;profile=mcp-app";
const PROTOCOL_VERSION = "2025-06-18";

function parseArgv(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i]?.replace(/^--/, "");
    if (key) out[key] = argv[i + 1];
  }
  return out;
}

// A stateless Streamable HTTP MCP endpoint answers each POST with either a
// JSON body or an SSE stream carrying one JSON-RPC response. Handle both.
async function rpc(url, sessionId, id, method, params) {
  const headers = {
    "Content-Type": "application/json",
    Accept: "application/json, text/event-stream",
  };
  if (sessionId) headers["mcp-session-id"] = sessionId;
  const body = { jsonrpc: "2.0", method, params };
  if (id !== null) body.id = id;

  const res = await fetch(url, { method: "POST", headers, body: JSON.stringify(body) });
  const newSession = res.headers.get("mcp-session-id") || sessionId;
  if (id === null) return { sessionId: newSession, result: null }; // notification

  const ct = res.headers.get("content-type") || "";
  const text = await res.text();
  if (!res.ok) throw new Error(`HTTP ${res.status} for ${method}: ${text.slice(0, 500)}`);

  let message;
  if (ct.includes("text/event-stream")) {
    // Collect `data:` lines; the JSON-RPC response is the one whose id matches.
    const dataLines = text
      .split(/\r?\n/)
      .filter((l) => l.startsWith("data:"))
      .map((l) => l.slice(5).trim())
      .filter(Boolean);
    for (const line of dataLines) {
      try {
        const parsed = JSON.parse(line);
        if (parsed.id === id) { message = parsed; break; }
        message = parsed;
      } catch { /* skip keepalives */ }
    }
  } else {
    message = JSON.parse(text);
  }

  if (!message) throw new Error(`No JSON-RPC response for ${method}`);
  if (message.error) throw new Error(`RPC error for ${method}: ${JSON.stringify(message.error)}`);
  return { sessionId: newSession, result: message.result };
}

async function main() {
  const args = parseArgv(process.argv.slice(2));
  const url = args.url;
  const toolName = args.tool;
  const toolArgs = args.args ? JSON.parse(args.args) : {};
  if (!url || !toolName) throw new Error("Usage: --url <mcp-url> --tool <name> [--args <json>]");

  let sessionId;

  // 1. initialize handshake (declare the UI extension capability)
  const init = await rpc(url, sessionId, 1, "initialize", {
    protocolVersion: PROTOCOL_VERSION,
    capabilities: { experimental: { "io.modelcontextprotocol/ui": {} } },
    clientInfo: { name: "zimmer-mcp-apps-host", version: "0.1.0" },
  });
  sessionId = init.sessionId;
  const serverInfo = init.result?.serverInfo || null;
  await rpc(url, sessionId, null, "notifications/initialized", {});

  // 2. discover the tool + the ui:// resource it declares via _meta.ui.resourceUri
  const toolsList = await rpc(url, sessionId, 2, "tools/list", {});
  const tool = (toolsList.result?.tools || []).find((t) => t.name === toolName);
  if (!tool) throw new Error(`Tool not found: ${toolName}`);
  const meta = tool._meta || {};
  const resourceUri = meta.ui?.resourceUri || meta["ui/resourceUri"];
  if (!resourceUri) throw new Error(`Tool ${toolName} declares no _meta.ui.resourceUri — not an MCP App`);

  // 3. call the tool (this is the same call the headless agent would make)
  const call = await rpc(url, sessionId, 3, "tools/call", { name: toolName, arguments: toolArgs });
  const toolResult = call.result;

  // 4. read the UI resource (the HTML fragment + CSP metadata)
  const read = await rpc(url, sessionId, 4, "resources/read", { uri: resourceUri });
  const contents = read.result?.contents || [];
  const content = contents[0];
  if (!content) throw new Error(`Empty resource: ${resourceUri}`);
  if (content.mimeType !== RESOURCE_MIME_TYPE) {
    throw new Error(`Unexpected mimeType ${content.mimeType} (want ${RESOURCE_MIME_TYPE})`);
  }
  const html = "blob" in content && content.blob ? Buffer.from(content.blob, "base64").toString("utf8") : content.text;
  const uiMeta = (content._meta || content.meta || {}).ui || {};

  // Emit the FULL tool (incl. inputSchema) — the MCP-Apps host contract passes
  // it back to the View as hostContext.toolInfo.tool, and the View validates it
  // as a complete MCP Tool (inputSchema is required).
  process.stdout.write(JSON.stringify({
    serverInfo,
    tool,
    input: toolArgs,
    toolResult,
    ui: { uri: resourceUri, mimeType: content.mimeType, html, csp: uiMeta.csp || null, permissions: uiMeta.permissions || null },
  }));
}

main().catch((err) => {
  process.stderr.write(String(err?.stack || err) + "\n");
  process.exit(1);
});
