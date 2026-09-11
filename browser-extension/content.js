// The pin and the composer, injected into the current tab when the toolbar
// icon is clicked. Everything it draws lives in a shadow root on one host
// element, so the page's CSS cannot restyle it and it cannot restyle the page.
//
// The flow: arm → the page gets a crosshair and a banner → one click drops the
// pin and opens the composer → Send hands the payload to the service worker,
// which is the only part that talks to Zimmer → a toast with a link to the new
// session. Esc backs out of any step. Enter while armed skips the pin.
//
// Idempotent under re-injection: clicking the icon twice arms once.
(() => {
  if (window.__zimmerQuickRouter) {
    return;
  }

  const START_MESSAGE = "zimmer-quick-router:start";
  const SUBMIT_MESSAGE = "zimmer-quick-router:submit";
  const HOST_ID = "zimmer-quick-router-host";

  // How much of the page travels with the message, after the DOM is reduced
  // to markdown. The same cap as the in-app bubble; Zimmer cuts again at
  // 50,000. The pin's own fields have their own, separate caps below, so a
  // long page never truncates away the thing that was pinned.
  const PAGE_CONTEXT_MAX = 20000;
  const PIN_TEXT_MAX = 1000;
  const PIN_EXCERPT_MAX = 4000;
  const PIN_SELECTOR_MAX = 500;

  // ---- Markdown, ported from app/javascript/controllers/chat_bubble_controller.js ----

  function tableToMarkdown(table) {
    const rows = [];
    let separatorAdded = false;
    for (const row of table.querySelectorAll("tr")) {
      const cells = Array.from(row.querySelectorAll("th, td")).map((c) => c.textContent.trim());
      rows.push(`| ${cells.join(" | ")} |`);
      if (row.querySelector("th") && !separatorAdded) {
        rows.push(`| ${cells.map(() => "---").join(" | ")} |`);
        separatorAdded = true;
      }
    }
    return rows.join("\n");
  }

  function htmlToMarkdown(element, maxLength) {
    const lines = [];
    let currentLength = 0;

    const walk = (node) => {
      if (currentLength > maxLength) return;

      if (node.nodeType === Node.TEXT_NODE) {
        const text = node.textContent.trim();
        if (text) {
          lines.push(text);
          currentLength += text.length + 1;
        }
        return;
      }
      if (node.nodeType !== Node.ELEMENT_NODE) return;

      const tag = node.tagName.toLowerCase();
      switch (tag) {
        case "h1":
        case "h2":
        case "h3":
        case "h4":
        case "h5":
        case "h6":
          lines.push(`\n${"#".repeat(parseInt(tag[1], 10))} ${node.textContent.trim()}`);
          return;
        case "p":
          lines.push(`\n${node.textContent.trim()}`);
          return;
        case "a": {
          const href = node.getAttribute("href");
          const text = node.textContent.trim();
          if (href && text) lines.push(`[${text}](${href})`);
          else if (text) lines.push(text);
          return;
        }
        case "li":
          lines.push(`- ${node.textContent.trim()}`);
          return;
        case "strong":
        case "b":
          lines.push(`**${node.textContent.trim()}**`);
          return;
        case "em":
        case "i":
          lines.push(`*${node.textContent.trim()}*`);
          return;
        case "code":
          lines.push(`\`${node.textContent.trim()}\``);
          return;
        case "pre":
          lines.push(`\n\`\`\`\n${node.textContent.trim()}\n\`\`\``);
          return;
        case "br":
          lines.push("");
          return;
        case "hr":
          lines.push("\n---");
          return;
        case "img":
          lines.push(`[${node.getAttribute("alt") || "image"}]`);
          return;
        case "table":
          lines.push(`\n${tableToMarkdown(node)}`);
          return;
        case "textarea":
        case "input":
          // A form's contents are the human's, not the page's.
          return;
        default:
          for (const child of node.childNodes) walk(child);
      }
    };

    walk(element);

    let result = lines.join("\n").replace(/\n{3,}/g, "\n\n").trim();
    if (result.length > maxLength) {
      result = `${result.substring(0, maxLength)}\n\n[...truncated]`;
    }
    return result;
  }

  function stripNoise(root) {
    root.querySelectorAll(`script, style, link, svg, noscript, template, iframe, [hidden], [aria-hidden='true'], #${HOST_ID}`)
      .forEach((el) => el.remove());
    return root;
  }

  function capturePageContext() {
    const clone = document.body.cloneNode(true);
    return htmlToMarkdown(stripNoise(clone), PAGE_CONTEXT_MAX);
  }

  // ---- The pin: the element under the click, described three ways ----

  // A selector that will find this element again in an unchanged page, and
  // reads as a path a human can follow in a changed one. Anchors on the
  // nearest id, since ids survive reflows and re-renders better than depth.
  function selectorFor(element) {
    const parts = [];
    let node = element;
    while (node && node.nodeType === Node.ELEMENT_NODE && node !== document.body && parts.length < 12) {
      const tag = node.tagName.toLowerCase();
      if (node.id && !/^\d/.test(node.id)) {
        parts.unshift(`#${CSS.escape(node.id)}`);
        break;
      }
      let part = tag;
      const parent = node.parentElement;
      if (parent) {
        const siblings = Array.from(parent.children).filter((c) => c.tagName === node.tagName);
        if (siblings.length > 1) part += `:nth-of-type(${siblings.indexOf(node) + 1})`;
      }
      parts.unshift(part);
      node = parent;
    }
    return parts.join(" > ").slice(0, PIN_SELECTOR_MAX);
  }

  function ownText(element) {
    if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement) {
      return element.value || element.placeholder || "";
    }
    if (element instanceof HTMLImageElement) return element.alt || element.src || "";
    return (element.innerText || element.textContent || "").trim().replace(/\s+/g, " ");
  }

  // The smallest ancestor with enough text around the pin to read in isolation
  // — a comment, a list item, a table row, a paragraph with its neighbours.
  function excerptFor(element) {
    let node = element;
    let hops = 0;
    while (node && node !== document.body && hops < 6) {
      const text = (node.innerText || node.textContent || "").trim();
      if (text.length >= 120) break;
      node = node.parentElement;
      hops += 1;
    }
    if (!node || node === document.body) node = element;
    const clone = node.cloneNode(true);
    return htmlToMarkdown(stripNoise(clone), PIN_EXCERPT_MAX);
  }

  function describePin(clientX, clientY, element) {
    return {
      x: Math.round(clientX + window.scrollX),
      y: Math.round(clientY + window.scrollY),
      viewport_width: window.innerWidth,
      viewport_height: window.innerHeight,
      selector: selectorFor(element),
      tag: element.tagName.toLowerCase(),
      text: ownText(element).slice(0, PIN_TEXT_MAX),
      excerpt: excerptFor(element)
    };
  }

  // ---- UI ----

  const STYLES = `
    :host { all: initial; }
    * { box-sizing: border-box; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
    .overlay { position: fixed; inset: 0; z-index: 2147483646; cursor: crosshair; background: rgba(79, 70, 229, 0.04); }
    .banner { position: fixed; top: 16px; left: 50%; transform: translateX(-50%); z-index: 2147483647;
      background: #1f2937; color: #f9fafb; font-size: 13px; line-height: 1.4; padding: 8px 14px; border-radius: 9999px;
      box-shadow: 0 8px 24px rgba(0,0,0,0.25); white-space: nowrap; pointer-events: none; max-width: calc(100vw - 32px); overflow: hidden; text-overflow: ellipsis; }
    .banner kbd { font-family: inherit; background: #374151; padding: 1px 6px; border-radius: 4px; font-size: 12px; }
    .pin { position: absolute; width: 22px; height: 22px; margin: -11px 0 0 -11px; border-radius: 9999px 9999px 9999px 0;
      transform: rotate(-45deg); background: #4f46e5; border: 3px solid #fff; box-shadow: 0 2px 8px rgba(0,0,0,0.35); z-index: 2147483647; pointer-events: none; }
    .composer { position: fixed; right: 16px; bottom: 16px; width: 380px; max-width: calc(100vw - 32px); z-index: 2147483647;
      background: #fff; color: #111827; border: 1px solid #e5e7eb; border-radius: 12px; box-shadow: 0 16px 48px rgba(0,0,0,0.25); overflow: hidden; }
    .composer header { display: flex; align-items: center; justify-content: space-between; padding: 10px 14px; background: #4f46e5; color: #fff; font-size: 14px; font-weight: 600; }
    .composer header button { all: unset; cursor: pointer; font-size: 18px; line-height: 1; padding: 2px 6px; border-radius: 6px; }
    .composer header button:hover { background: rgba(255,255,255,0.15); }
    .anchor { font-size: 12px; color: #4b5563; padding: 8px 14px; background: #f9fafb; border-bottom: 1px solid #e5e7eb; display: flex; gap: 8px; align-items: baseline; }
    .anchor .tag { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; color: #4f46e5; flex: none; }
    .anchor .text { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .anchor button { all: unset; cursor: pointer; color: #4f46e5; font-size: 12px; flex: none; }
    .anchor button:hover { text-decoration: underline; }
    textarea { display: block; width: 100%; min-height: 96px; max-height: 40vh; resize: vertical; border: 0; outline: 0; padding: 12px 14px; font-size: 14px; line-height: 1.5; color: #111827; background: #fff; }
    textarea::placeholder { color: #9ca3af; }
    .actions { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 10px 14px; border-top: 1px solid #e5e7eb; font-size: 12px; color: #6b7280; }
    .actions .hint { flex: 1; min-width: 0; }
    .send { all: unset; cursor: pointer; background: #4f46e5; color: #fff; font-size: 13px; font-weight: 600; padding: 7px 14px; border-radius: 8px; }
    .send:hover { background: #4338ca; }
    .send[disabled] { opacity: 0.6; cursor: default; }
    .error { padding: 8px 14px; font-size: 12px; color: #991b1b; background: #fef2f2; border-top: 1px solid #fecaca; }
    .toast { position: fixed; right: 16px; bottom: 16px; z-index: 2147483647; background: #065f46; color: #ecfdf5; font-size: 13px; padding: 10px 14px; border-radius: 10px;
      box-shadow: 0 8px 24px rgba(0,0,0,0.25); display: flex; gap: 12px; align-items: center; max-width: calc(100vw - 32px); }
    .toast a { color: #fff; font-weight: 600; }
    .toast button { all: unset; cursor: pointer; font-size: 16px; line-height: 1; padding: 0 4px; }
    @media (max-width: 480px) { .composer { right: 8px; left: 8px; bottom: 8px; width: auto; max-width: none; } }
  `;

  const state = { host: null, root: null, overlay: null, banner: null, pinEl: null, composer: null, pin: null, draft: "" };

  function mount() {
    if (state.host) return;
    const host = document.createElement("div");
    host.id = HOST_ID;
    host.style.cssText = "position:absolute;top:0;left:0;width:0;height:0;overflow:visible;z-index:2147483647;";
    const root = host.attachShadow({ mode: "open" });
    const style = document.createElement("style");
    style.textContent = STYLES;
    root.appendChild(style);
    document.documentElement.appendChild(host);
    state.host = host;
    state.root = root;
    document.addEventListener("keydown", onKeydown, true);
  }

  function unmount() {
    document.removeEventListener("keydown", onKeydown, true);
    state.host?.remove();
    Object.assign(state, { host: null, root: null, overlay: null, banner: null, pinEl: null, composer: null, pin: null });
  }

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function arm() {
    mount();
    if (state.overlay) return;

    state.overlay = el("div", "overlay");
    state.banner = el("div", "banner");
    state.banner.innerHTML = "Click where your feedback applies &nbsp;·&nbsp; <kbd>Enter</kbd> skips the pin &nbsp;·&nbsp; <kbd>Esc</kbd> cancels";
    state.overlay.addEventListener("click", onOverlayClick);
    state.root.append(state.overlay, state.banner);
  }

  function disarm() {
    state.overlay?.remove();
    state.banner?.remove();
    state.overlay = null;
    state.banner = null;
  }

  function onOverlayClick(event) {
    event.preventDefault();
    event.stopPropagation();
    const { clientX, clientY } = event;

    // Sample the page under the click, not our own overlay.
    state.host.style.display = "none";
    const target = document.elementFromPoint(clientX, clientY) || document.body;
    state.host.style.display = "";

    state.pin = describePin(clientX, clientY, target);
    disarm();
    dropPin(state.pin.x, state.pin.y);
    openComposer();
  }

  function dropPin(pageX, pageY) {
    state.pinEl?.remove();
    state.pinEl = el("div", "pin");
    state.pinEl.style.left = `${pageX}px`;
    state.pinEl.style.top = `${pageY}px`;
    state.root.appendChild(state.pinEl);
  }

  function openComposer() {
    state.composer?.remove();
    const composer = el("div", "composer");

    const header = el("header");
    header.append(el("span", null, "Quick Router"));
    const close = el("button", null, "×");
    close.title = "Cancel (Esc)";
    close.addEventListener("click", cancel);
    header.append(close);
    composer.append(header);

    const anchor = el("div", "anchor");
    if (state.pin) {
      anchor.append(el("span", "tag", `<${state.pin.tag}>`));
      anchor.append(el("span", "text", state.pin.text || "(no text)"));
      const repin = el("button", null, "Move pin");
      repin.addEventListener("click", () => {
        composer.remove();
        state.composer = null;
        state.pinEl?.remove();
        state.pinEl = null;
        state.pin = null;
        arm();
      });
      anchor.append(repin);
    } else {
      anchor.append(el("span", "text", "No pin — the whole page is the context."));
      const addPin = el("button", null, "Drop a pin");
      addPin.addEventListener("click", () => {
        composer.remove();
        state.composer = null;
        arm();
      });
      anchor.append(addPin);
    }
    composer.append(anchor);

    const textarea = el("textarea");
    textarea.placeholder = "What did you notice? An agent session picks this up with the page and the pin.";
    textarea.value = state.draft;
    textarea.addEventListener("input", () => { state.draft = textarea.value; });
    textarea.addEventListener("keydown", (event) => {
      if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
        event.preventDefault();
        send();
      }
    });
    composer.append(textarea);

    const actions = el("div", "actions");
    actions.append(el("span", "hint", `${navigator.platform.startsWith("Mac") ? "⌘" : "Ctrl"}+Enter to send`));
    const sendButton = el("button", "send", "Send to Zimmer");
    sendButton.addEventListener("click", send);
    actions.append(sendButton);
    composer.append(actions);

    state.root.appendChild(composer);
    state.composer = composer;
    textarea.focus();
  }

  function showError(message) {
    state.composer?.querySelector(".error")?.remove();
    const error = el("div", "error", message);
    state.composer?.appendChild(error);
    const button = state.composer?.querySelector(".send");
    if (button) {
      button.disabled = false;
      button.textContent = "Send to Zimmer";
    }
  }

  async function send() {
    const textarea = state.composer?.querySelector("textarea");
    const button = state.composer?.querySelector(".send");
    const prompt = (textarea?.value || "").trim();
    if (!prompt) {
      textarea?.focus();
      return;
    }

    button.disabled = true;
    button.textContent = "Sending…";
    state.composer.querySelector(".error")?.remove();

    const payload = {
      prompt,
      page_url: location.href,
      page_title: document.title,
      page_context: capturePageContext(),
      pin: state.pin
    };

    let result;
    try {
      result = await chrome.runtime.sendMessage({ type: SUBMIT_MESSAGE, payload });
    } catch (error) {
      result = { ok: false, error: `The extension's background worker did not answer (${error?.message || error}). Try again.` };
    }

    if (!result?.ok) {
      showError(result?.error || "Zimmer did not accept the message.");
      return;
    }

    state.draft = "";
    state.composer.remove();
    state.composer = null;
    state.pinEl?.remove();
    state.pinEl = null;
    toast(result.sessionUrl);
  }

  // Sent. A link to the session, gone on its own in a few seconds — the point
  // of the whole thing is not having to go anywhere.
  function toast(sessionUrl) {
    const node = el("div", "toast");
    node.append(el("span", null, "Sent to Zimmer."));
    if (sessionUrl) {
      const link = el("a", null, "Open session ↗");
      link.href = sessionUrl;
      link.target = "_blank";
      link.rel = "noopener";
      node.append(link);
    }
    const dismiss = el("button", null, "×");
    dismiss.addEventListener("click", () => finish());
    node.append(dismiss);
    state.root.appendChild(node);
    setTimeout(() => finish(), 8000);
  }

  function finish() {
    unmount();
  }

  function cancel() {
    state.draft = "";
    unmount();
  }

  function onKeydown(event) {
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      cancel();
      return;
    }
    if (event.key === "Enter" && state.overlay && !state.composer) {
      event.preventDefault();
      event.stopPropagation();
      state.pin = null;
      disarm();
      openComposer();
    }
  }

  chrome.runtime.onMessage.addListener((message) => {
    if (message?.type !== START_MESSAGE) return;
    if (state.composer) {
      state.composer.querySelector("textarea")?.focus();
      return;
    }
    arm();
  });

  window.__zimmerQuickRouter = { version: 1 };
})();
