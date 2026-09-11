import { Controller } from "@hotwired/stimulus"

// The browser half of Zimmer-as-MCP-host (SEP-1865 / io.modelcontextprotocol/ui).
//
// The fragment is loaded into an iframe that has no `allow-same-origin`, so it
// is in an opaque origin: it cannot read this page, this page cannot read it,
// and `postMessage` is the only channel between them. This controller is the
// broker on Zimmer's side of that channel.
//
// It answers three classes of message, and the division is the whole design:
//
//   * `ui/*` — the host protocol. Answered here, from data the server already
//     rendered into this element: the tool, the arguments the agent used, and
//     the result that call already returned. No network.
//   * `ui/message` and `ui/update-model-context` — the view speaking to the
//     agent. POSTed to Zimmer, which turns it into a real turn (or queues it).
//   * anything else — a real MCP request for the server. POSTed to Zimmer,
//     which decides whether to forward it and holds the credential. The browser
//     never talks to the MCP server and never sees a token.
//
// Every message is checked against `event.source` before it is read. The frame
// is the only window whose messages this controller will act on.
export default class extends Controller {
  static values = {
    fragmentUrl: String,
    rpcUrl: String,
    messageUrl: String,
    sandbox: String,
    tool: Object,
    toolInput: Object,
    toolResult: Object,
    hasResult: Boolean,
    styles: Object,
    theme: { type: String, default: "light" },
  }
  static targets = ["frame", "status", "container", "fullscreenButton"]

  // The MCP Apps revisions this host will speak. The handshake echoes back
  // whichever of these the view asked for, and answers with the first otherwise
  // — the same negotiation MCP itself uses, and not optional: the reference SDK
  // stalls in `connect()` when the host answers a version it did not ask for,
  // which presents as a view that renders and then never initializes.
  static PROTOCOL_VERSIONS = ["2026-01-26", "2025-11-21"]

  // Display modes this host can put a view into. Used both for what it
  // advertises and for what it will agree to switch to.
  static DISPLAY_MODES = ["inline", "fullscreen"]

  // What the host can do, in the spec's own `HostCapabilities` shape. Only what
  // is actually implemented is declared — a capability a host announces and then
  // does not answer leaves a view waiting forever.
  static HOST_CAPABILITIES = {
    openLinks: {},
    serverTools: {},
    serverResources: {},
    logging: {},
  }

  connect() {
    this.displayMode = "inline"
    // Until the view says otherwise, assume it can take either mode: the spec
    // constrains the host only when `availableDisplayModes` is actually set.
    this.appDisplayModes = this.constructor.DISPLAY_MODES
    this.protocolVersion = this.constructor.PROTOCOL_VERSIONS[0]
    this.initialized = false
    this.onMessage = this.handleMessage.bind(this)
    window.addEventListener("message", this.onMessage)

    this.frameTarget.setAttribute("sandbox", this.sandboxValue)
    this.frameTarget.src = this.fragmentUrlValue
    this.setStatus("loading view…")
  }

  disconnect() {
    window.removeEventListener("message", this.onMessage)
  }

  get appWindow() {
    return this.hasFrameTarget ? this.frameTarget.contentWindow : null
  }

  handleMessage(event) {
    const appWindow = this.appWindow
    if (!appWindow || event.source !== appWindow) return

    const message = event.data
    if (!message || message.jsonrpc !== "2.0") return
    // The frame is untrusted, so `method` is whatever it felt like sending. A
    // number here would throw out of `startsWith` below, and the view would then
    // wait forever for a reply this controller never got as far as writing.
    if (message.method !== undefined && typeof message.method !== "string") return

    if (message.method && message.id !== undefined && message.id !== null) {
      this.handleRequest(message)
    } else if (message.method) {
      this.handleNotification(message)
    }
  }

  async handleRequest({ id, method, params }) {
    // Per the spec, anything that is not a `ui/` method (and is not `ping`) is a
    // real MCP request the host forwards to the server on the view's behalf.
    if (!method.startsWith("ui/") && method !== "ping") {
      return this.forwardToServer(id, method, params)
    }

    switch (method) {
      case "ui/initialize":
        this.protocolVersion = this.negotiate(params?.protocolVersion)
        this.appDisplayModes =
          params?.appCapabilities?.availableDisplayModes || this.constructor.DISPLAY_MODES
        this.respond(id, this.initializeResult())
        this.syncFullscreenButton()
        this.setStatus("connected")
        break
      case "ui/message":
        await this.sendToAgent(id, this.textFrom(params?.content), "message")
        break
      case "ui/update-model-context":
        await this.sendToAgent(
          id,
          this.textFrom(params?.content) || this.jsonFrom(params?.structuredContent),
          "context"
        )
        break
      case "ui/open-link":
        // A sandboxed document cannot navigate the top frame and has no
        // `allow-popups`, so opening a link is something it asks the host for.
        // Opened with `noopener` so the new tab holds no handle on this one.
        if (this.safeLink(params?.url)) {
          window.open(params.url, "_blank", "noopener,noreferrer")
          this.respond(id, {})
        } else {
          this.respondError(id, -32602, "only http(s) links can be opened")
        }
        break
      case "ui/request-display-mode":
        this.respond(id, { mode: this.applyDisplayMode(params?.mode) })
        break
      case "ping":
        this.respond(id, {})
        break
      default:
        this.respondError(id, -32601, `${method} is not supported by this host`)
    }
  }

  handleNotification({ method, params }) {
    switch (method) {
      case "ui/notifications/initialized":
        // The spec forbids the host sending anything to the view before this
        // notification arrives, which is why tool-input and tool-result are sent
        // from here and not from the initialize response.
        if (this.initialized) return
        this.initialized = true
        this.notify("ui/notifications/tool-input", { arguments: this.toolInputValue || {} })
        if (this.hasResultValue) {
          this.notify("ui/notifications/tool-result", this.toolResultValue || {})
          this.setStatus("ready")
        } else {
          // The agent's call has no result in the transcript yet. Saying so is
          // better than sending an empty one, which a view would render as a
          // successful call that returned nothing.
          this.setStatus("waiting for the tool result")
        }
        break
      case "ui/notifications/size-changed":
        this.applySize(params)
        break
      case "notifications/message":
        this.setStatus(this.truncate(`log: ${params?.data ?? ""}`))
        break
      default:
        break
    }
  }

  // --- View -> Server, via Rails ------------------------------------------
  async forwardToServer(id, method, params) {
    this.setStatus(this.truncate(`→ ${method}`))
    try {
      const body = await this.post(this.rpcUrlValue, { method_name: method, params: params || {} })
      if (body.error) {
        this.respondError(id, body.error.code || -32603, body.error.message || "request failed")
        this.setStatus(this.truncate(`✗ ${method}: ${body.error.message || ""}`))
      } else {
        this.respond(id, body.result)
        this.setStatus(this.truncate(`← ${method}`))
      }
    } catch (error) {
      this.respondError(id, -32603, error.message || String(error))
      this.setStatus(this.truncate(`✗ ${method}`))
    }
  }

  // --- View -> Agent, via Rails -------------------------------------------
  async sendToAgent(id, text, kind) {
    if (!text) {
      this.respondError(id, -32602, "no text content")
      return
    }

    try {
      const body = await this.post(this.messageUrlValue, { text, kind })
      if (body.status === "rejected") {
        this.respondError(id, -32000, body.message || "the session cannot take this message")
        this.setStatus(this.truncate(`✗ ${body.message || "rejected"}`))
      } else {
        this.respond(id, {})
        this.setStatus(body.status === "queued" ? "queued for the agent" : "sent to the agent")
      }
    } catch (error) {
      this.respondError(id, -32000, error.message || String(error))
      this.setStatus("✗ could not reach Zimmer")
    }
  }

  async post(url, payload) {
    const response = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-CSRF-Token": this.csrfToken(),
      },
      credentials: "same-origin",
      body: JSON.stringify(payload),
    })

    if (!response.ok && response.status !== 422) {
      throw new Error(`Zimmer returned HTTP ${response.status}`)
    }
    return await response.json()
  }

  csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }

  // --- Host context --------------------------------------------------------
  initializeResult() {
    return {
      protocolVersion: this.protocolVersion,
      hostInfo: { name: "zimmer", version: "1.0.0" },
      hostCapabilities: this.constructor.HOST_CAPABILITIES,
      hostContext: {
        toolInfo: { tool: this.toolValue || {} },
        theme: this.themeValue,
        styles: this.stylesValue || {},
        displayMode: this.displayMode,
        availableDisplayModes: this.constructor.DISPLAY_MODES,
        // Flexible in both directions, bounded. The view decides its own size
        // and tells us via size-changed; the caps are the width of the column
        // it is embedded in, and a height that keeps one panel from burying the
        // transcript around it. Stating maxWidth matters on a phone, where it
        // is the difference between a view that lays itself out for 343px and
        // one that renders a desktop card the reader has to scroll sideways.
        containerDimensions: { maxWidth: this.containerWidth(), maxHeight: this.maxHeight() },
        platform: "web",
        locale: document.documentElement.lang || "en-US",
        userAgent: "zimmer-session-detail",
      },
    }
  }

  negotiate(requested) {
    const versions = this.constructor.PROTOCOL_VERSIONS
    return versions.includes(requested) ? requested : versions[0]
  }

  applyDisplayMode(requested) {
    if (requested === this.displayMode) return this.displayMode
    if (!this.constructor.DISPLAY_MODES.includes(requested)) return this.displayMode
    if (!this.appDisplayModes.includes(requested)) return this.displayMode

    this.setDisplayMode(requested)
    return this.displayMode
  }

  toggleFullscreen() {
    this.setDisplayMode(this.displayMode === "fullscreen" ? "inline" : "fullscreen")
  }

  setDisplayMode(mode) {
    this.displayMode = mode
    this.element.classList.toggle("fixed", mode === "fullscreen")
    this.element.classList.toggle("inset-2", mode === "fullscreen")
    this.element.classList.toggle("z-50", mode === "fullscreen")
    this.element.classList.toggle("overflow-auto", mode === "fullscreen")
    this.applyHeight(this.lastHeight)
    this.notify("ui/notifications/host-context-changed", {
      displayMode: mode,
      containerDimensions: { maxWidth: this.containerWidth(), maxHeight: this.maxHeight() },
    })
  }

  syncFullscreenButton() {
    if (!this.hasFullscreenButtonTarget) return
    this.fullscreenButtonTarget.hidden = !this.appDisplayModes.includes("fullscreen")
  }

  applySize(params) {
    if (!params) return
    if (typeof params.height === "number") {
      this.lastHeight = params.height
      this.applyHeight(params.height)
    }
    if (typeof params.width === "number") this.applyWidth(params.width)
  }

  applyHeight(height) {
    if (!height) return
    this.frameTarget.style.height = `${Math.min(Math.max(height, 80), this.maxHeight())}px`
  }

  // A view that reports itself wider than the column it is in gets that width,
  // and the container scrolls to it. Clipping instead would put the right-hand
  // end of somebody's widget — which is where buttons live — permanently out of
  // reach on a phone.
  applyWidth(width) {
    const available = this.containerWidth()
    this.frameTarget.style.width = width > available ? `${Math.min(width, 2000)}px` : "100%"
  }

  containerWidth() {
    const target = this.hasContainerTarget ? this.containerTarget : this.element
    return Math.round(target.clientWidth) || 320
  }

  maxHeight() {
    return this.displayMode === "fullscreen" ? Math.max(window.innerHeight - 120, 320) : 640
  }

  // --- Small helpers -------------------------------------------------------
  // `ui/message` carries a single ContentBlock in the spec and an array in some
  // SDKs. Both are read, because a view that sends the shape its own SDK
  // produces is not doing anything wrong.
  textFrom(content) {
    const blocks = Array.isArray(content) ? content : content ? [content] : []
    return blocks
      .filter((block) => block && block.type === "text" && typeof block.text === "string")
      .map((block) => block.text)
      .join(" ")
      .trim()
  }

  jsonFrom(structured) {
    if (!structured || typeof structured !== "object") return ""
    try {
      return JSON.stringify(structured)
    } catch {
      return ""
    }
  }

  safeLink(url) {
    try {
      return ["http:", "https:"].includes(new URL(url).protocol)
    } catch {
      return false
    }
  }

  truncate(text) {
    return text.length > 70 ? `${text.slice(0, 69)}…` : text
  }

  respond(id, result) {
    this.postToApp({ jsonrpc: "2.0", id, result: result === undefined ? {} : result })
  }

  respondError(id, code, message) {
    this.postToApp({ jsonrpc: "2.0", id, error: { code, message } })
  }

  notify(method, params) {
    this.postToApp({ jsonrpc: "2.0", method, params })
  }

  // The target origin is `*` because the frame has an opaque origin — there is
  // no origin string that would match it. That is safe here only because the
  // frame is one this page created and holds a handle to: `contentWindow` is
  // not reachable by any other document.
  postToApp(message) {
    const appWindow = this.appWindow
    if (appWindow) appWindow.postMessage(message, "*")
  }

  setStatus(text) {
    if (this.hasStatusTarget) this.statusTarget.textContent = text
  }
}
