// The browser extension, end to end: the real unpacked extension loaded into
// Chromium, armed on a real page, a pin dropped, a message sent, and the
// session it made read back from Zimmer. Not run in CI (see
// docs/src/content/docs/operate/testing.md) — run it by hand against a local
// server:
//
//   BASE_URL=http://localhost:3000 QUICK_ROUTER_KEY=zmr_… node test/e2e/browser_extension_test.js
//
// QUICK_ROUTER_KEY is a key minted on /settings/api_keys with "Quick Router
// only" chosen. TARGET_URL (default: a public GitHub PR) is the page to pin on;
// SCREENSHOT_DIR, when set, gets a PNG of each step.
//
// Two things a real install gets interactively that Playwright cannot click
// through — Chrome's permission bubble for the Zimmer origin, and the toolbar
// click that grants `activeTab` — the harness grants statically, by loading a
// copy of the extension whose manifest lists both origins under
// `host_permissions`. Nothing else in the copy differs from browser-extension/.
const { chromium } = require('playwright');
const fs = require('fs');
const os = require('os');
const path = require('path');

(async () => {
  const BASE_URL = (process.env.BASE_URL || 'http://localhost:3000').replace(/\/$/, '');
  const KEY = process.env.QUICK_ROUTER_KEY;
  const TARGET_URL = process.env.TARGET_URL || 'https://github.com/tadasant/zimmer/pull/1150';
  const SHOTS = process.env.SCREENSHOT_DIR;
  if (!KEY) {
    console.error('QUICK_ROUTER_KEY is required — mint one on /settings/api_keys with "Quick Router only".');
    process.exit(2);
  }

  let passed = 0, failed = 0;
  const assert = (condition, name) => {
    console.log(`  ${condition ? 'PASS' : 'FAIL'}: ${name}`);
    condition ? passed++ : failed++;
  };
  const shot = async (page, name) => { if (SHOTS) await page.screenshot({ path: path.join(SHOTS, `${name}.png`) }); };

  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'zimmer-ext-e2e-'));
  const ext = path.join(work, 'extension');
  fs.cpSync(path.join(__dirname, '..', '..', 'browser-extension'), ext, { recursive: true });
  const manifest = JSON.parse(fs.readFileSync(path.join(ext, 'manifest.json')));
  manifest.host_permissions = [`${BASE_URL}/*`, `${new URL(TARGET_URL).origin}/*`];
  fs.writeFileSync(path.join(ext, 'manifest.json'), JSON.stringify(manifest, null, 2));

  const context = await chromium.launchPersistentContext(path.join(work, 'profile'), {
    channel: 'chromium', // the headless shell cannot load extensions; the full Chromium can
    headless: true,
    viewport: { width: 1440, height: 900 },
    args: [`--disable-extensions-except=${ext}`, `--load-extension=${ext}`]
  });

  console.log('=== Browser extension E2E ===\n');
  try {
    const worker = context.serviceWorkers()[0] || await context.waitForEvent('serviceworker');
    const extId = new URL(worker.url()).host;

    console.log('Step 1: options page saves the URL and key...');
    const options = await context.newPage();
    await options.goto(`chrome-extension://${extId}/options.html`);
    await options.waitForFunction(() => document.getElementById('status').textContent.length > 0);
    assert((await options.textContent('#status')).includes('Not configured'), 'a fresh install says it is not configured');
    await options.fill('#baseUrl', BASE_URL);
    await options.fill('#apiKey', KEY);
    await options.click('button[type=submit]');
    await options.waitForFunction(() => document.getElementById('status').textContent.includes('Configured'));
    assert(true, `save reports configured for ${BASE_URL}`);
    await shot(options, '01-options');
    await options.close();

    console.log('Step 2: arm on the target page, drop a pin, send...');
    const page = await context.newPage();
    await page.goto(TARGET_URL, { waitUntil: 'domcontentloaded', timeout: 60000 });
    const arm = () => worker.evaluate(async (url) => {
      const [tab] = await chrome.tabs.query({ url: `${new URL(url).origin}/*` });
      await arm(tab);
    }, TARGET_URL);
    await arm();
    const host = page.locator('#zimmer-quick-router-host');
    await host.locator('.overlay').waitFor();
    assert(true, 'the overlay and banner appear');
    await shot(page, '02-armed');

    const target = page.locator('p:visible').filter({ hasText: /\S/ }).first();
    await target.scrollIntoViewIfNeeded();
    const box = await target.boundingBox();
    await page.mouse.click(box.x + Math.min(box.width / 2, 200), box.y + box.height / 2);
    await host.locator('.composer').waitFor();
    const anchorText = await host.locator('.anchor').innerText();
    assert(anchorText.includes('<p>'), `the composer names the pinned element (${anchorText.split('\n')[0]})`);
    await shot(page, '03-composer');

    const message = `e2e ${new Date().toISOString()}: pinned feedback from the extension`;
    await host.locator('textarea').fill(message);
    await host.locator('.send').click();
    await host.locator('.toast').waitFor({ timeout: 30000 });
    const sessionUrl = await host.locator('.toast a').getAttribute('href');
    assert(/\/sessions\/\d+$/.test(sessionUrl || ''), `the toast links to a session (${sessionUrl})`);
    await shot(page, '04-toast');
    await host.locator('.toast button').click();

    console.log('Step 3: a wrong key is refused and the text survives...');
    await worker.evaluate(() => chrome.storage.local.set({ apiKey: 'zmr_not_the_key' }));
    await arm();
    await host.locator('.overlay').waitFor();
    await page.keyboard.press('Enter');
    await host.locator('.composer').waitFor();
    assert((await host.locator('.anchor').innerText()).includes('No pin'), 'Enter skips the pin');
    await host.locator('textarea').fill('will be refused');
    await host.locator('.send').click();
    await host.locator('.error').waitFor({ timeout: 30000 });
    assert((await host.locator('.error').innerText()).includes('refused'), 'Zimmer\'s refusal is shown in the composer');
    assert((await host.locator('textarea').inputValue()) === 'will be refused', 'the text is kept for a retry');
    await shot(page, '05-refused');
    await page.keyboard.press('Escape');
    assert((await host.count()) === 0, 'Esc tears everything down');
    await page.close();

    console.log('Step 4: the session exists in Zimmer...');
    const z = await context.newPage();
    const response = await z.goto(sessionUrl, { waitUntil: 'networkidle' });
    assert(response.ok(), `GET ${sessionUrl} -> ${response.status()}`);
    await shot(z, '06-session');
    await z.close();
  } finally {
    await context.close();
    fs.rmSync(work, { recursive: true, force: true });
  }

  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed === 0 ? 0 : 1);
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
