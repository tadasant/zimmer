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

// A click on the toolbar icon (or the keyboard command bound to it) arms the
// pin on the current tab. `activeTab` grants this tab, this once — the
// extension holds no standing permission on any site.
chrome.action.onClicked.addListener((tab) => arm(tab));

async function arm(tab) {
  if (!tab?.id) return;

  const settings = await Settings.loadSettings();
  if (!settings.baseUrl || !settings.apiKey) {
    chrome.runtime.openOptionsPage();
    return;
  }

  try {
    await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["content.js"] });
    await chrome.tabs.sendMessage(tab.id, { type: START_MESSAGE });
  } catch (error) {
    // chrome:// pages, the Web Store, and PDF viewers refuse injection. There
    // is no page to pin on, so there is nothing to tell the user in-page.
    console.warn("[zimmer] cannot arm the pin on this tab:", error?.message || error);
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
      body: JSON.stringify(payload)
    });
  } catch (error) {
    return { ok: false, error: `Could not reach ${baseUrl} (${error?.message || error}). On the tailnet?` };
  }

  let body = {};
  try {
    body = (await response.json()) || {};
  } catch {
    // A proxy error page is not JSON; the status code is the message then.
  }

  if (!response.ok) {
    const detail = body.message || `HTTP ${response.status}`;
    const hint = response.status === 401 ? " Check the key in the extension's options — it must be a Quick Router key." : "";
    return { ok: false, error: `Zimmer refused it: ${detail}.${hint}` };
  }

  // Linked on the URL this browser just reached, not the one Zimmer reports:
  // the instance's configured base URL may be a name this browser cannot
  // resolve, while `baseUrl` demonstrably works from here.
  const sessionUrl = body.session_id ? `${baseUrl}/sessions/${body.session_id}` : body.session_url;
  return { ok: true, sessionId: body.session_id, sessionUrl };
}
