// The extension's two settings, and the one place their shape is decided.
//
// Stored in chrome.storage.local rather than .sync on purpose: the key opens a
// session-spawning endpoint on a private instance, and a key that follows a
// Google account onto every signed-in machine is a wider blast radius than the
// one browser it was minted for.
const SETTINGS_KEYS = ["baseUrl", "apiKey"];

// "https://zimmer.example.com/" and "zimmer.example.com" both become an origin
// with no trailing slash; anything that is not an http(s) URL is rejected.
function normalizeBaseUrl(input) {
  let text = String(input || "").trim();
  if (!text) return null;
  if (!/^https?:\/\//i.test(text)) text = `https://${text}`;
  let url;
  try {
    url = new URL(text);
  } catch {
    return null;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return null;
  return url.origin;
}

// The host-permission pattern the service worker needs for fetches to this
// origin to be exempt from CORS.
function originPattern(baseUrl) {
  return `${baseUrl}/*`;
}

async function loadSettings() {
  const stored = await chrome.storage.local.get(SETTINGS_KEYS);
  return { baseUrl: stored.baseUrl || "", apiKey: stored.apiKey || "" };
}

async function saveSettings({ baseUrl, apiKey }) {
  await chrome.storage.local.set({ baseUrl, apiKey });
}

// Service workers and extension pages load this file differently (importScripts
// vs a <script> tag), so it publishes onto the global rather than exporting.
globalThis.ZimmerSettings = { normalizeBaseUrl, originPattern, loadSettings, saveSettings };
