// The options page: the Zimmer URL and the Quick Router key, and the one
// host-permission request that lets the service worker reach that URL.
// settings.js shares this global scope, so its functions are reached through the
// namespace it publishes rather than re-declared here.
const Settings = globalThis.ZimmerSettings;

const form = document.getElementById("form");
const baseUrlInput = document.getElementById("baseUrl");
const apiKeyInput = document.getElementById("apiKey");
const keysLink = document.getElementById("keysLink");
const status = document.getElementById("status");
const reveal = document.getElementById("reveal");

function setStatus(text, ok) {
  status.textContent = text;
  status.className = `status ${ok ? "ok" : "bad"}`;
}

function pointKeysLinkAt(baseUrl) {
  keysLink.href = baseUrl ? `${baseUrl}/settings/api_keys` : "#";
}

async function describeCurrent() {
  const { baseUrl, apiKey } = await Settings.loadSettings();
  baseUrlInput.value = baseUrl;
  apiKeyInput.value = apiKey;
  pointKeysLinkAt(baseUrl);
  if (!baseUrl || !apiKey) {
    setStatus("Not configured yet.", false);
    return;
  }
  const granted = await chrome.permissions.contains({ origins: [Settings.originPattern(baseUrl)] });
  setStatus(granted ? `Configured for ${baseUrl}.` : `Saved, but Chrome has not granted access to ${baseUrl} — save again.`, granted);
}

baseUrlInput.addEventListener("input", () => pointKeysLinkAt(Settings.normalizeBaseUrl(baseUrlInput.value)));

reveal.addEventListener("click", () => {
  const showing = apiKeyInput.type === "text";
  apiKeyInput.type = showing ? "password" : "text";
  reveal.textContent = showing ? "Show key" : "Hide key";
});

form.addEventListener("submit", async (event) => {
  event.preventDefault();

  const baseUrl = Settings.normalizeBaseUrl(baseUrlInput.value);
  const apiKey = apiKeyInput.value.trim();
  if (!baseUrl) {
    setStatus("That is not an http(s) URL.", false);
    return;
  }
  if (!apiKey) {
    setStatus("Paste the Quick Router key.", false);
    return;
  }

  // Must run inside the click's user gesture, so it comes before any other await.
  const granted = await chrome.permissions.request({ origins: [Settings.originPattern(baseUrl)] });
  const previous = (await Settings.loadSettings()).baseUrl;
  await Settings.saveSettings({ baseUrl, apiKey });
  // A changed URL should not leave the extension holding access to the old one.
  if (previous && previous !== baseUrl) {
    await chrome.permissions.remove({ origins: [Settings.originPattern(previous)] }).catch(() => {});
  }
  baseUrlInput.value = baseUrl;
  pointKeysLinkAt(baseUrl);
  setStatus(granted ? `Saved. Configured for ${baseUrl}.` : `Saved, but without permission to reach ${baseUrl} the extension cannot send anything.`, granted);
});

describeCurrent();
