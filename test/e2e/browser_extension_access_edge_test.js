// The browser extension behind an access proxy: the real unpacked extension in
// Chromium, sending to a Zimmer URL that sits behind Cloudflare Access — as
// zimmer.tadasant.com does. Self-contained: no Zimmer server and no key needed.
//
//   node test/e2e/browser_extension_access_edge_test.js
//
// A stand-in for the edge answers on http://localhost:<port>, the way Access
// does: `/` signs the browser in by setting `CF_Authorization` (SameSite=Lax,
// HttpOnly — the strictest cookie Access sets), and `POST /api/v1/quick_router`
// without that cookie gets Access's own 401, an HTML page with a
// `cf-access-domain` header that never reaches Zimmer — or, once told to, a
// redirect to its login page. With the cookie it answers the way Zimmer's
// ingest does, including Zimmer's own JSON 401 for a key it does not know.
//
// What it proves: a browser that has signed in to the edge sends the Quick
// Router message through it, one that has not is told to sign in rather than
// that its key is wrong, and a wrong key is still blamed on the key.
const { chromium } = require('playwright');
const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');

const FIXTURE = '<!doctype html><html><head><title>Fixture</title></head><body><h1>Fixture page</h1><p>Some text to send.</p></body></html>';

(async () => {
  let passed = 0, failed = 0;
  const assert = (condition, name) => {
    console.log(`  ${condition ? 'PASS' : 'FAIL'}: ${name}`);
    condition ? passed++ : failed++;
  };

  const KEY = 'zmr_quick_router_key';
  const received = [];
  let redirectSignedOut = false;
  const edge = http.createServer((req, res) => {
    const signedIn = /(?:^|;\s*)CF_Authorization=signed-in(?:;|$)/.test(req.headers.cookie || '');
    if (req.method === 'GET' && req.url === '/') {
      res.setHeader('Set-Cookie', 'CF_Authorization=signed-in; Path=/; HttpOnly; SameSite=Lax');
      res.setHeader('Content-Type', 'text/html');
      return res.end('<!doctype html><title>Zimmer</title><p>signed in</p>');
    }
    if (req.method === 'POST' && req.url === '/api/v1/quick_router') {
      if (!signedIn && redirectSignedOut) {
        res.writeHead(302, { Location: '/cdn-cgi/access/login' });
        return res.end();
      }
      if (!signedIn) {
        res.writeHead(401, { 'Content-Type': 'text/html', 'cf-access-domain': req.headers.host });
        return res.end('<!doctype html><title>Error ・ Cloudflare Access</title>');
      }
      let body = '';
      req.on('data', (chunk) => { body += chunk; });
      req.on('end', () => {
        if (req.headers['x-api-key'] !== KEY) {
          res.writeHead(401, { 'Content-Type': 'application/json' });
          return res.end(JSON.stringify({ error: 'Unauthorized', message: 'Invalid or missing API key', messages: ['Invalid or missing API key'] }));
        }
        received.push({ key: req.headers['x-api-key'], body: JSON.parse(body) });
        res.writeHead(201, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ session_id: 4242, session_url: 'http://unreachable.example/sessions/4242' }));
      });
      return;
    }
    res.writeHead(404);
    res.end();
  });
  await new Promise((resolve) => edge.listen(0, '127.0.0.1', resolve));
  // `localhost`, so the edge is a different site from the page on 127.0.0.1.
  const BASE_URL = `http://localhost:${edge.address().port}`;

  const fixtureServer = http.createServer((_req, res) => { res.setHeader('Content-Type', 'text/html'); res.end(FIXTURE); });
  await new Promise((resolve) => fixtureServer.listen(0, '127.0.0.1', resolve));
  const FIXTURE_URL = `http://127.0.0.1:${fixtureServer.address().port}/`;

  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'zimmer-ext-edge-e2e-'));
  const ext = path.join(work, 'extension');
  fs.cpSync(path.join(__dirname, '..', '..', 'browser-extension'), ext, { recursive: true });
  // Granted statically, for the reason browser_extension_test.js gives.
  const manifest = JSON.parse(fs.readFileSync(path.join(ext, 'manifest.json')));
  manifest.host_permissions = [`${BASE_URL}/*`, 'http://127.0.0.1/*'];
  fs.writeFileSync(path.join(ext, 'manifest.json'), JSON.stringify(manifest, null, 2));

  const context = await chromium.launchPersistentContext(path.join(work, 'profile'), {
    channel: 'chromium',
    headless: true,
    args: [`--disable-extensions-except=${ext}`, `--load-extension=${ext}`]
  });

  console.log('=== Browser extension behind an access proxy ===\n');
  try {
    const worker = context.serviceWorkers()[0] || await context.waitForEvent('serviceworker');
    await worker.evaluate(([url, k]) => chrome.storage.local.set({ baseUrl: url, apiKey: k }), [BASE_URL, KEY]);

    const page = await context.newPage();
    await page.goto(FIXTURE_URL);
    const host = page.locator('#zimmer-quick-router-host');
    const send = async (text) => {
      await worker.evaluate(async () => {
        const [tab] = await chrome.tabs.query({ url: 'http://127.0.0.1/*' });
        await arm(tab, { pin: false });
      });
      await host.locator('.composer').waitFor();
      await host.locator('textarea').fill(text);
      await host.locator('.send').click();
    };

    console.log('Step 1: a browser not signed in to the edge is told to sign in...');
    await send('before signing in');
    await host.locator('.error').waitFor({ timeout: 30000 });
    const refusal = await host.locator('.error').innerText();
    assert(refusal.includes('sign in') && refusal.includes(BASE_URL), `the composer says to sign in at the Zimmer URL (${refusal})`);
    assert(!refusal.includes('Quick Router key'), 'it does not blame the key');
    assert((await host.locator('textarea').inputValue()) === 'before signing in', 'the text is kept for a retry');
    assert(received.length === 0, 'nothing reached the ingest');
    await page.keyboard.press('Escape');

    console.log('Step 2: once signed in, the same message goes through the edge...');
    const signIn = await context.newPage();
    await signIn.goto(`${BASE_URL}/`);
    await signIn.close();
    await send('after signing in');
    await host.locator('.toast').waitFor({ timeout: 30000 });
    const link = await host.locator('.toast a').getAttribute('href');
    assert(link === `${BASE_URL}/sessions/4242`, `the toast links to the session on the URL the browser reached (${link})`);
    assert(received.length === 1, `the ingest received one request (${received.length})`);
    assert(received[0]?.key === 'zmr_quick_router_key', 'with the key in X-API-Key');
    assert(received[0]?.body?.prompt === 'after signing in', 'and the message as the prompt');
    await host.locator('.toast button').click();

    console.log('Step 3: past the edge, a wrong key is still blamed on the key...');
    await worker.evaluate(() => chrome.storage.local.set({ apiKey: 'zmr_not_the_key' }));
    await send('with the wrong key');
    await host.locator('.error').waitFor({ timeout: 30000 });
    const wrongKey = await host.locator('.error').innerText();
    assert(wrongKey.includes('Invalid or missing API key') && wrongKey.includes('Quick Router key'), `Zimmer's own refusal names the key (${wrongKey})`);
    await page.keyboard.press('Escape');
    await worker.evaluate((k) => chrome.storage.local.set({ apiKey: k }), KEY);

    console.log('Step 4: an edge that redirects to its login page is not taken for a success...');
    await context.clearCookies();
    redirectSignedOut = true;
    await send('redirected to sign in');
    await host.locator('.error').waitFor({ timeout: 30000 });
    const redirected = await host.locator('.error').innerText();
    assert(redirected.includes('sign in') && redirected.includes(BASE_URL), `the redirect reads as a sign-in, not a sent message (${redirected})`);
    assert(received.length === 1, 'nothing more reached the ingest');
  } finally {
    edge.close();
    fixtureServer.close();
    await context.close();
    fs.rmSync(work, { recursive: true, force: true });
  }

  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed === 0 ? 0 : 1);
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
