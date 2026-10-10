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
      // never redirects this endpoint, so a redirect is reported rather than
      // followed: following one would POST to a login page and read its 200
      // as a sent message.
      credentials: "include",
      redirect: "manual"
    });
  } catch (error) {
    return { ok: false, error: `Could not reach ${baseUrl} (${error?.message || error}). Is the URL right, and can this browser reach it?` };
  }

  const refusal = accessProxyRefusal(response, baseUrl);
  if (refusal) return { ok: false, error: refusal };

  let body = {};
  try {
    body = (await response.json()) || {};
  } catch {
    // A proxy error page is not JSON; the status code is the message then.
  }

  if (!response.ok) {
    const detail = body.message || `HTTP ${response.status}`;
    // Only Zimmer's own 401 is about the key; it answers in JSON with a message.
    const hint = response.status === 401 && body.message ? " Check the key in the extension's options. It must be a Quick Router key that has not been revoked." : "";
    return { ok: false, error: `Zimmer refused it: ${detail}.${hint}` };
  }

  if (!body.session_id && !body.session_url) {
    return { ok: false, error: `${baseUrl} answered, but not as Zimmer: no session came back. Is the URL right?` };
  }

  // Linked on the URL this browser just reached, not the one Zimmer reports:
  // the instance's configured base URL may be a name this browser cannot
  // resolve, while `baseUrl` demonstrably works from here.
  const sessionUrl = body.session_id ? `${baseUrl}/sessions/${body.session_id}` : body.session_url;
  return { ok: true, sessionId: body.session_id, sessionUrl };
}

// What to tell the human when something in front of Zimmer answered instead of
// Zimmer, or null when Zimmer answered. Cloudflare Access marks its own
// refusals with `cf-access-domain`: a 401 when the browser has no valid sign-in
// there, a 403 when it has one that the policy does not admit. A redirect —
// `redirect: "manual"` makes it an opaque response with status 0 — is Access
// sending the request to its login page, or an http URL being sent to https.
function accessProxyRefusal(response, baseUrl) {
  if (response.type === "opaqueredirect") {
    if (baseUrl.startsWith("http:")) {
      return `${baseUrl} redirected the request instead of answering it. Try the https:// URL in the extension's options.`;
    }
    return `${baseUrl} redirected the request instead of answering it, most likely to an access proxy's sign-in page. Open ${baseUrl} in a tab, sign in, then send again.`;
  }
  if (!response.headers.has("cf-access-domain")) return null;
  if (response.status === 401) {
    return `The access proxy in front of Zimmer stopped it before Zimmer saw it. This browser is not signed in there: open ${baseUrl} in a tab, sign in, then send again.`;
  }
  if (response.status === 403) {
    return `The access proxy in front of Zimmer refused the account this browser is signed in with. Open ${baseUrl} in a tab and sign in with the account the deployment admits.`;
  }
  return null;
}
