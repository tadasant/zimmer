// The service worker: the only part of the extension that talks to Zimmer.
//
// The fetch lives here and not in the content script because of where each
// runs. A content script makes requests as the page it was injected into, so
// github.com calling a Zimmer host is a cross-origin request and Zimmer would
// need CORS to answer it. An extension service worker makes requests as the
// extension, and Chrome exempts those from CORS for any host the extension holds
// a host permission for — which the options page asks for when the Zimmer URL is
// saved. Zimmer keeps having no CORS at all.
importScripts("settings.js");

const Settings = globalThis.ZimmerSettings;

const START_MESSAGE = "zimmer-quick-router:start";
const SUBMIT_MESSAGE = "zimmer-quick-router:submit";
const DROP_PIN_COMMAND = "drop-pin";

// Two ways to start on the current tab. The toolbar icon, and Alt+Shift+Z bound
// to it, open the composer at once with the whole page as the context; the
// `drop-pin` command, Alt+Shift+X, starts with the crosshair. Either gesture
// grants `activeTab` for this tab, this once — the extension holds no standing
// permission on any site.
chrome.action.onClicked.addListener((tab) => arm(tab, { pin: false }));

chrome.commands.onCommand.addListener((command, tab) => {
  if (command === DROP_PIN_COMMAND) arm(tab, { pin: true });
});

async function arm(tab, { pin }) {
  if (!tab?.id) return;

  const settings = await Settings.loadSettings();
  if (!settings.baseUrl || !settings.apiKey) {
    chrome.runtime.openOptionsPage();
    return;
  }

  try {
    await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["content.js"] });
    await chrome.tabs.sendMessage(tab.id, { type: START_MESSAGE, pin });
  } catch (error) {
    // chrome:// pages, the Web Store, and PDF viewers refuse injection. There
    // is no page to draw on, so there is nothing to tell the user in-page.
    console.warn("[zimmer] cannot start on this tab:", error?.message || error);
  }
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== SUBMIT_MESSAGE) return false;

  submit(message.payload)
    .then(sendResponse)
    .catch((error) => sendResponse({ ok: false, error: error?.message || String(error) }));
  return true; // keep the channel open for the async response
});

// POST the payload to Zimmer and report back in one of three shapes the
// content script renders: sent, refused (with Zimmer's own message), or
// unreachable. Nothing is retried here — the composer keeps the text, and the
// human decides.
async function submit(payload) {
  const { baseUrl, apiKey } = await Settings.loadSettings();
  if (!baseUrl || !apiKey) {
    return { ok: false, error: "Zimmer isn't configured yet — set the URL and key in the extension's options." };
  }

  const granted = await chrome.permissions.contains({ origins: [Settings.originPattern(baseUrl)] });
  if (!granted) {
    return { ok: false, error: `The extension has no permission to reach ${baseUrl}. Re-save the URL in its options to grant it.` };
  }

  let response;
  try {
    response = await fetch(`${baseUrl}/api/v1/quick_router`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-API-Key": apiKey },
      body: JSON.stringify(payload),
      // A deployment behind an access proxy (Cloudflare Access) admits the
      // request on the browser's own sign-in cookie for that origin. Zimmer
      // never redirects this endpoint, so a redirect is the proxy sending the
      // request to its login page — surfaced, not followed.
      credentials: "include",
      redirect: "manual"
    });
  } catch (error) {
    return { ok: false, error: `Could not reach ${baseUrl} (${error?.message || error}). On the tailnet?` };
  }

  if (refusedByAccessProxy(response)) {
    return { ok: false, error: `The access proxy in front of Zimmer stopped it before Zimmer saw it — this browser is not signed in there. Open ${baseUrl} in a tab, sign in, then send again.` };
  }

  let body = {};
  try {
    body = (await response.json()) || {};
  } catch {
    // A proxy error page is not JSON; the status code is the message then.
  }

  if (!response.ok) {
    const detail = body.message || `HTTP ${response.status}`;
    // Only Zimmer's own 401 is about the key; it answers in JSON with a message.
    const hint = response.status === 401 && body.message ? " Check the key in the extension's options — it must be a Quick Router key." : "";
    return { ok: false, error: `Zimmer refused it: ${detail}.${hint}` };
  }

  if (!body.session_id && !body.session_url) {
    return { ok: false, error: `${baseUrl} answered, but not as Zimmer — no session came back. Is the URL right?` };
  }

  // Linked on the URL this browser just reached, not the one Zimmer reports:
  // the instance's configured base URL may be a name this browser cannot
  // resolve, while `baseUrl` demonstrably works from here.
  const sessionUrl = body.session_id ? `${baseUrl}/sessions/${body.session_id}` : body.session_url;
  return { ok: true, sessionId: body.session_id, sessionUrl };
}

// Cloudflare Access refuses a request with no valid sign-in cookie itself,
// before it reaches Zimmer: a 401 or 403 carrying `cf-access-domain`, or — for
// a request it would rather send to its login page — a redirect, which
// `redirect: "manual"` turns into an opaque response with status 0.
function refusedByAccessProxy(response) {
  if (response.type === "opaqueredirect") return true;
  return (response.status === 401 || response.status === 403) && response.headers.has("cf-access-domain");
}
