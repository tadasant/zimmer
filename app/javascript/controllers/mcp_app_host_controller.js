import { Controller } from "@hotwired/stimulus"

// MCP Apps host broker (SEP-1865 / io.modelcontextprotocol/ui) — spike.
//
// This is the browser half of Zimmer-acting-as-its-own-MCP-host. The server
// half (McpAppPreviewService -> Node bridge) has already connected to an
// app-capable MCP server, called a tool, and handed us three things via data
// attributes: the tool's `ui://` HTML fragment, the tool's CallToolResult, and
// the tool metadata. We render the fragment in a sandboxed iframe and speak the
// MCP-Apps postMessage protocol to it: answer its `ui/initialize` handshake with
// host context, then push it the tool input + result. The fragment (an MCP App
// "View", which acts as an MCP client over postMessage) renders itself.
//
// Message method names + payload shapes are taken verbatim from the ext-apps
// spec (specification/2026-01-26/apps.mdx) and SDK (src/spec.types.ts).
//
// NOTE (spike scope): the spec's full security model wraps the View in a
// separate-origin "sandbox proxy" iframe with header-based CSP. Here we render
// the View directly into one sandboxed (`allow-scripts`, opaque-origin) iframe
// via srcdoc. That's enough to prove the rendering + protocol works; a
// production version would add the second-origin proxy. See the docs page.
export default class extends Controller {
  static values = {
    html: String,
    toolResult: Object,
    tool: Object,
    input: Object,
    theme: { type: String, default: "light" },
  }
  static targets = ["frame", "status"]

  connect() {
    this._onMessage = this.handleMessage.bind(this)
    window.addEventListener("message", this._onMessage)
    this.render()
  }

  disconnect() {
    window.removeEventListener("message", this._onMessage)
  }

  render() {
    const iframe = this.frameTarget
    // allow-scripts (no allow-same-origin) => opaque origin, real isolation.
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

    // Requests carry an id and expect a response; notifications do not.
    if (msg.id !== undefined && msg.id !== null && msg.method) {
      this.handleRequest(msg)
    } else if (msg.method) {
      this.handleNotification(msg)
    }
  }

  handleRequest(msg) {
    switch (msg.method) {
      case "ui/initialize":
        this.respond(msg.id, this.initializeResult())
        this.setStatus("handshake ✓ — waiting for view…")
        break
      case "ui/open-link":
        if (msg.params?.url) window.open(msg.params.url, "_blank", "noopener,noreferrer")
        this.respond(msg.id, {})
        break
      case "ping":
        this.respond(msg.id, {})
        break
      default:
        // Answer any other View->Host request so the View never hangs waiting.
        this.respond(msg.id, {})
    }
  }

  handleNotification(msg) {
    switch (msg.method) {
      case "ui/notifications/initialized":
        // View is ready. Deliver the tool input then the tool result.
        this.notify("ui/notifications/tool-input", { arguments: this.inputValue || {} })
        this.notify("ui/notifications/tool-result", this.toolResultValue || {})
        this.setStatus("fragment live ✓")
        break
      case "ui/notifications/size-changed":
        this.applySize(msg.params)
        break
      default:
        // ignore other View->Host notifications (logging, model-context, etc.)
        break
    }
  }

  initializeResult() {
    return {
      protocolVersion: "2026-01-26",
      hostInfo: { name: "zimmer", version: "0.1.0" },
      hostCapabilities: {
        openLinks: {},
        serverTools: {},
        serverResources: {},
        logging: {},
      },
      hostContext: {
        toolInfo: { tool: this.toolValue || {} },
        theme: this.themeValue,
        platform: "web",
        displayMode: "inline",
        availableDisplayModes: ["inline"],
        containerDimensions: { width: this.frameTarget.clientWidth || 360, maxHeight: 640 },
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
