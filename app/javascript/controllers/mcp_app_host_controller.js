import { Controller } from "@hotwired/stimulus"

// MCP Apps host broker (SEP-1865 / io.modelcontextprotocol/ui) — spike.
//
// The browser half of Zimmer-acting-as-its-own-MCP-host. The server half
// (McpAppPreviewService -> Node bridge) has already connected to an app-capable
// MCP server, called a tool, and handed us the ui:// fragment + CallToolResult.
// We render the fragment in a sandboxed iframe and speak the MCP-Apps
// postMessage protocol to it.
//
// Interactivity (the interesting part) has two flavors, both handled here:
//
//   1. View -> Server: the fragment calls `tools/call` / `resources/read`. Per
//      the spec, the host forwards any non-`ui/`-prefixed method to the MCP
//      server. We proxy it over Streamable HTTP (the demo servers send CORS *),
//      and hand the result back. No agent involved.
//
//   2. View -> Agent: the fragment calls `ui/message` (sendMessage) or
//      `ui/update-model-context`. Since Zimmer's agent is headless Claude Code,
//      "send to the model" means "stage a follow-up prompt for the session."
//      We drop the text into the session's follow-up textarea. In production
//      this would enqueue a real turn.
//
// Method names + payload shapes are verbatim from the spec
// (specification/2026-01-26/apps.mdx) and SDK (src/spec.types.ts).
export default class extends Controller {
  static values = {
    html: String,
    toolResult: Object,
    tool: Object,
    input: Object,
    theme: { type: String, default: "light" },
    serverUrl: String,
    sessionId: String,
  }
  static targets = ["frame", "status"]

  connect() {
    this._rpcId = 0
    this._onMessage = this.handleMessage.bind(this)
    window.addEventListener("message", this._onMessage)
    this.render()
  }

  disconnect() {
    window.removeEventListener("message", this._onMessage)
  }

  render() {
    const iframe = this.frameTarget
    iframe.setAttribute("sandbox", "allow-scripts allow-popups")
    iframe.srcdoc = this.htmlValue
    this.setStatus("rendering fragment…")
  }

  get appWindow() {
    return this.frameTarget.contentWindow
  }

  handleMessage(event) {
    if (event.source !== this.appWindow) return
    const msg = event.data
    if (!msg || msg.jsonrpc !== "2.0") return
    if (msg.id !== undefined && msg.id !== null && msg.method) {
      this.handleRequest(msg)
    } else if (msg.method) {
      this.handleNotification(msg)
    }
  }

  async handleRequest(msg) {
    const { id, method, params } = msg
    // Anything that isn't a `ui/` method (and isn't ping) is a real MCP request
    // destined for the server — proxy it. This is how View->Server tool calls work.
    if (!method.startsWith("ui/") && method !== "ping") {
      return this.proxyToServer(id, method, params)
    }

    switch (method) {
      case "ui/initialize":
        this.respond(id, this.initializeResult())
        this.setStatus("handshake ✓ — waiting for view…")
        break
      case "ui/message":
        this.routeToAgent(this.textFrom(params?.content), "message")
        this.respond(id, {})
        break
      case "ui/update-model-context":
        this.routeToAgent(this.textFrom(params?.content) || JSON.stringify(params?.structuredContent || {}), "context")
        this.respond(id, {})
        break
      case "ui/open-link":
        if (params?.url) window.open(params.url, "_blank", "noopener,noreferrer")
        this.respond(id, {})
        break
      case "ping":
        this.respond(id, {})
        break
      default:
        this.respond(id, {})
    }
  }

  handleNotification(msg) {
    switch (msg.method) {
      case "ui/notifications/initialized":
        this.notify("ui/notifications/tool-input", { arguments: this.inputValue || {} })
        this.notify("ui/notifications/tool-result", this.toolResultValue || {})
        this.setStatus("fragment live ✓")
        break
      case "ui/notifications/size-changed":
        this.applySize(msg.params)
        break
      case "notifications/message": // sendLog from the view
        this.setStatus(`log: ${msg.params?.data ?? ""}`.slice(0, 60))
        break
      default:
        break
    }
  }

  // --- View -> Server proxy (Streamable HTTP MCP over fetch) --------------
  async proxyToServer(id, method, params) {
    if (!this.serverUrlValue) {
      return this.respondError(id, -32601, `no server configured to proxy ${method}`)
    }
    try {
      this.setStatus(`→ ${method}…`)
      const result = await this.mcpRpc(method, params)
      this.respond(id, result)
      this.setStatus(`← ${method} ✓`)
    } catch (e) {
      this.respondError(id, -32603, e.message || String(e))
      this.setStatus(`✗ ${method}`)
    }
  }

  async mcpRpc(method, params) {
    const reqId = `h${++this._rpcId}`
    const res = await fetch(this.serverUrlValue, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json, text/event-stream" },
      body: JSON.stringify({ jsonrpc: "2.0", id: reqId, method, params }),
    })
    const ct = res.headers.get("content-type") || ""
    const text = await res.text()
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    let message
    if (ct.includes("text/event-stream")) {
      for (const line of text.split(/\r?\n/)) {
        if (!line.startsWith("data:")) continue
        try {
          const parsed = JSON.parse(line.slice(5).trim())
          if (parsed.id === reqId) { message = parsed; break }
          message = parsed
        } catch { /* keepalive */ }
      }
    } else {
      message = JSON.parse(text)
    }
    if (!message) throw new Error("empty response")
    if (message.error) throw new Error(message.error.message || "rpc error")
    return message.result
  }

  // --- View -> Agent: stage the text as a session follow-up prompt --------
  routeToAgent(text, kind) {
    if (!text) return
    const ta = this.sessionIdValue
      ? document.getElementById(`session_${this.sessionIdValue}_follow_up_textarea`)
      : null
    if (ta) {
      ta.value = ta.value ? `${ta.value}\n${text}` : text
      ta.dispatchEvent(new Event("input", { bubbles: true }))
      ta.focus()
    }
    this.setStatus(`→ agent (${kind}): ${text}`.slice(0, 70))
  }

  textFrom(content) {
    if (!Array.isArray(content)) return ""
    return content.filter((b) => b && b.type === "text").map((b) => b.text).join(" ").trim()
  }

  initializeResult() {
    return {
      protocolVersion: "2026-01-26",
      hostInfo: { name: "zimmer", version: "0.1.0" },
      hostCapabilities: {
        openLinks: {},
        serverTools: {},
        serverResources: {},
        updateModelContext: { text: {} },
        logging: {},
      },
      hostContext: {
        toolInfo: { tool: this.toolValue || {} },
        theme: this.themeValue,
        platform: "web",
        displayMode: "inline",
        availableDisplayModes: ["inline"],
        containerDimensions: { width: this.frameTarget.clientWidth || 380, maxHeight: 640 },
        userAgent: "zimmer-session-detail",
      },
    }
  }

  applySize(params) {
    if (!params) return
    if (typeof params.height === "number") {
      this.frameTarget.style.height = `${Math.min(params.height, 640)}px`
    }
  }

  respond(id, result) {
    this.post({ jsonrpc: "2.0", id, result })
  }

  respondError(id, code, message) {
    this.post({ jsonrpc: "2.0", id, error: { code, message } })
  }

  notify(method, params) {
    this.post({ jsonrpc: "2.0", method, params })
  }

  post(message) {
    if (this.appWindow) this.appWindow.postMessage(message, "*")
  }

  setStatus(text) {
    if (this.hasStatusTarget) this.statusTarget.textContent = text
  }
}
