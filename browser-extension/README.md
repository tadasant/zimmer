# Zimmer Quick Router — browser extension

The Quick Router bubble, from any page on the web. Click the toolbar icon, click the thing your
feedback is about, type, send. A Zimmer agent session starts with your words, the page's URL and
content, and the spot you pinned. You never leave the page.

Chrome, Manifest V3, no build step. The docs page is
[Extend → The browser extension](https://docs.zimmer.tadasant.com/extend/browser-extension/).

## Install

1. Open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked**, and pick this
   directory.
2. In Zimmer, open **Settings → API keys** and create a key with **Quick Router only** checked.
   Copy it — it is shown once.
3. Open the extension's options (right-click the icon → Options), paste the Zimmer URL and the
   key, and save. Saving asks Chrome for permission to talk to that one origin; grant it.

The browser has to be able to reach Zimmer. On a tailnet-scoped instance that means the browser
is on the tailnet.

## Use

- Click the icon, or press `Alt+Shift+Z`.
- Click where the feedback applies. `Enter` skips the pin; `Esc` cancels.
- Type, then `⌘/Ctrl+Enter`. A toast links to the session Zimmer started.

## What it sends, and what the key can do

One `POST /api/v1/quick_router` per message: the message, the page URL and title, the page reduced
to markdown (at most 20,000 characters), and — with a pin — the element under it: a CSS selector,
its tag, its text, and the content around it (at most 4,000 characters). Everything lands in the
new session's prompt.

The key is an API key with the `quick_router` grant. It opens that one endpoint and nothing else —
`/api/v1/*` and `/mcp` refuse it — so a key lifted from this browser can start Quick Router
sessions and read nothing back. Revoke it on the same settings page.

## Files

| File | What it is |
| --- | --- |
| `manifest.json` | MV3. `activeTab` + `scripting` for the current tab on click; `storage` for the two settings; host permission for the Zimmer origin only, requested at save time. |
| `background.js` | The service worker. The only part that talks to Zimmer — an extension's own fetch to a host it has permission for is exempt from CORS, so Zimmer needs none. |
| `content.js` | The pin overlay and the composer, in a shadow root. Injected on click, once per page. |
| `options.html`, `options.js`, `settings.js` | The options page and the settings shape it shares with the worker. |
