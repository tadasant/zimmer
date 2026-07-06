const { chromium } = require('playwright');

// E2E coverage for the mobile session-detail joystick menu (_mobile_joystick).
//
// Regression focus: the page-global chat-bubble FAB is `data-turbo-permanent`,
// so on a Turbo navigation it is transplanted out-of-band. A JS hook that tried
// to hide it on connect() raced that transplant and silently no-op'd, leaving
// the purple chat-bubble FAB stacked over the indigo radial trigger (equal
// z-50, later in DOM => paints on top) where it swallowed every tap. The fix
// suppresses the FAB with server-rendered CSS (no race). These tests assert,
// specifically after a Turbo navigation, that the radial trigger — not the
// chat-bubble FAB — is the hit-test winner at the bubble's center.
//
// Run against a live server:
//   BASE_URL=http://localhost:3000 node test/e2e/joystick_menu_test.js
//
// Like the other test/e2e/*.js scripts, this is a standalone runner (not part
// of the Rails CI suite). It exits non-zero if any assertion fails.

const MOBILE = { width: 390, height: 844 };
const DESKTOP = { width: 1280, height: 900 };

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: MOBILE,
    recordVideo: { dir: '/tmp/joystick-videos/', size: MOBILE }
  });
  const page = await context.newPage();
  const BASE_URL = process.env.BASE_URL || 'http://localhost:3000';

  console.log('=== Joystick Menu E2E Test ===\n');
  let passed = 0;
  let failed = 0;

  function assert(condition, testName) {
    if (condition) {
      console.log(`  PASS: ${testName}`);
      passed++;
    } else {
      console.log(`  FAIL: ${testName}`);
      failed++;
    }
  }

  // ---- Setup: get a session-detail page to test against ----
  // Prefer an existing session linked from the homepage (keeps the test fast and
  // deterministic, and exercises the real Turbo-navigation path later). Fall
  // back to creating one via the Quick Router if the homepage has none.
  console.log('Setup: locating a session-detail page...');
  await page.setViewportSize(DESKTOP);
  await page.goto(BASE_URL, { waitUntil: 'networkidle' });
  await page.waitForTimeout(300);

  let sessionPath = await page.evaluate(() => {
    const a = Array.from(document.querySelectorAll('a[href]'))
      .map(el => el.getAttribute('href'))
      .find(h => /^\/sessions\/\d+$/.test(h));
    return a || null;
  });

  if (!sessionPath) {
    console.log('  No existing session — creating one via the Quick Router...');
    await page.locator('#chat-bubble button[aria-label="Open quick router"]').click();
    await page.waitForTimeout(300);
    await page.locator('[data-chat-bubble-target="textarea"]').fill('Joystick e2e setup session');
    await page.locator('[data-chat-bubble-target="submitOpenButton"]').click();
    await page.waitForURL(/\/sessions\/\d+/, { timeout: 15000 });
    sessionPath = new URL(page.url()).pathname;
  }
  const sessionUrl = new URL(sessionPath, BASE_URL).href;
  console.log(`  Using session: ${sessionPath}\n`);

  // ---- Test 1: Desktop — joystick hidden, chat-bubble FAB visible ----
  console.log('Test 1: Desktop viewport hides joystick, keeps chat-bubble FAB...');
  await page.setViewportSize(DESKTOP);
  await page.goto(sessionUrl, { waitUntil: 'networkidle' });
  await page.waitForTimeout(400);
  const desktopState = await page.evaluate(() => {
    const wrapper = document.querySelector("[data-controller='joystick-menu']");
    const chatFab = document.querySelector('#chat-bubble > button');
    return {
      joystickHidden: wrapper ? getComputedStyle(wrapper).display === 'none' : null,
      chatFabVisible: chatFab ? getComputedStyle(chatFab).display !== 'none' : null
    };
  });
  assert(desktopState.joystickHidden === true, 'Joystick wrapper is hidden on desktop (md:hidden)');
  assert(desktopState.chatFabVisible === true, 'Chat-bubble FAB stays visible on desktop');

  // ---- Test 2: Mobile after TURBO navigation — the regression ----
  console.log('\nTest 2: Mobile, after Turbo navigation, radial trigger wins the hit test...');
  await page.setViewportSize(MOBILE);
  await page.goto(BASE_URL, { waitUntil: 'networkidle' });
  await page.waitForTimeout(300);
  // Click the session card link -> Turbo navigation (the path that reproduced the bug).
  await page.click(`a[href="${sessionPath}"], a[href$="${sessionPath}"]`);
  await page.waitForTimeout(1200);

  const regression = await page.evaluate(() => {
    const chatFab = document.querySelector('#chat-bubble > button');
    const notesToggle = document.querySelector("[data-session-notes-target='toggleButton']");
    const trigger = document.querySelector("[data-joystick-menu-target='trigger']");
    const out = {
      onSessionPage: /\/sessions\/\d+/.test(location.pathname),
      chatFabDisplay: chatFab ? getComputedStyle(chatFab).display : 'no-fab',
      notesToggleDisplay: notesToggle ? getComputedStyle(notesToggle).display : 'no-toggle',
      triggerExists: !!trigger
    };
    if (trigger) {
      const r = trigger.getBoundingClientRect();
      const top = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
      out.topInsideJoystick = !!(top && top.closest("[data-controller='joystick-menu']"));
      out.topInsideChatBubble = !!(top && top.closest('#chat-bubble'));
    }
    return out;
  });
  assert(regression.onSessionPage, 'Navigated to session detail page via Turbo');
  assert(regression.triggerExists, 'Radial trigger is rendered on mobile');
  assert(regression.chatFabDisplay === 'none', 'Chat-bubble FAB is suppressed on mobile (display:none)');
  assert(regression.notesToggleDisplay === 'none', 'Notes-drawer toggle is suppressed on mobile (display:none)');
  assert(regression.topInsideJoystick === true, 'Radial trigger is the top element at its center (post-Turbo)');
  assert(regression.topInsideChatBubble === false, 'Chat-bubble FAB no longer intercepts taps at that point');

  await page.screenshot({ path: '/tmp/joystick-01-mobile-session.png' });
  console.log('  Screenshot: /tmp/joystick-01-mobile-session.png');

  // Helper: center of the radial trigger.
  async function triggerCenter() {
    return page.evaluate(() => {
      const t = document.querySelector("[data-joystick-menu-target='trigger']");
      const b = t.getBoundingClientRect();
      return { cx: b.x + b.width / 2, cy: b.y + b.height / 2 };
    });
  }

  // ---- Test 3: Quick tap opens the bottom sheet ----
  console.log('\nTest 3: Quick tap opens the bottom sheet...');
  let c = await triggerCenter();
  await page.mouse.move(c.cx, c.cy);
  await page.mouse.down();
  await page.waitForTimeout(60);
  await page.mouse.up();
  await page.waitForTimeout(400);
  const sheet = await page.evaluate(() => {
    const s = document.querySelector("[data-joystick-menu-target='sheet']");
    const overlay = document.querySelector("[data-joystick-menu-target='sheetOverlay']");
    return {
      open: s ? !s.classList.contains('translate-y-full') : null,
      overlayVisible: overlay ? !overlay.classList.contains('hidden') : null,
      hasQuickRouter: !!s.querySelector("button[data-petal-key='quick-router']"),
      hasEditNotes: !!s.querySelector("button[data-petal-key='edit-notes']")
    };
  });
  assert(sheet.open === true, 'Bottom sheet slides open on quick tap');
  assert(sheet.overlayVisible === true, 'Bottom-sheet overlay is shown');
  assert(sheet.hasQuickRouter, 'Bottom sheet contains a Quick Router row');
  assert(sheet.hasEditNotes, 'Bottom sheet contains an Edit Notes row');
  await page.screenshot({ path: '/tmp/joystick-02-bottom-sheet.png' });
  console.log('  Screenshot: /tmp/joystick-02-bottom-sheet.png');

  // ---- Test 4: Quick Router from the sheet opens the chat-bubble panel ----
  console.log('\nTest 4: Quick Router (from sheet) opens the panel...');
  await page.click("[data-joystick-menu-target='sheet'] button[data-petal-key='quick-router']");
  await page.waitForTimeout(500);
  const panelFromSheet = await page.evaluate(() => {
    const panel = document.querySelector('[data-chat-bubble-target="panel"]');
    return {
      open: panel.classList.contains('translate-x-0') && panel.classList.contains('opacity-100'),
      header: document.querySelector('#chat-bubble h3')?.textContent.trim(),
      sheetClosed: document.querySelector("[data-joystick-menu-target='sheet']").classList.contains('translate-y-full')
    };
  });
  assert(panelFromSheet.open === true, 'Quick Router panel opens from the sheet');
  assert(panelFromSheet.header === 'Quick Router', 'Opened panel is the Quick Router');
  assert(panelFromSheet.sheetClosed === true, 'Bottom sheet closes after selecting Quick Router');
  await page.keyboard.press('Escape');
  await page.waitForTimeout(300);

  // ---- Test 5: Tap-and-hold + drag fans out the radial petals ----
  console.log('\nTest 5: Tap-and-hold + drag fans out the radial petals...');
  c = await triggerCenter();
  await page.mouse.move(c.cx, c.cy);
  await page.mouse.down();
  await page.waitForTimeout(150);
  await page.mouse.move(c.cx - 45, c.cy - 45, { steps: 8 });
  await page.waitForTimeout(300);
  const petals = await page.evaluate(() => {
    const ps = Array.from(document.querySelectorAll("[data-joystick-menu-target='petal']"));
    const overlay = document.querySelector("[data-joystick-menu-target='overlay']");
    return {
      count: ps.length,
      allVisible: ps.length > 0 && ps.every(p => getComputedStyle(p).opacity === '1'),
      allTranslated: ps.every(p => /translate\(/.test(p.style.transform) && p.style.transform !== 'translate(0px, 0px)'),
      overlayShown: overlay ? getComputedStyle(overlay).opacity === '1' : null
    };
  });
  assert(petals.count > 0, 'Radial petals are rendered');
  assert(petals.allVisible, 'All petals become visible while holding');
  assert(petals.allTranslated, 'All petals translate to their arc positions');
  assert(petals.overlayShown === true, 'Dim overlay is shown while expanded');
  await page.screenshot({ path: '/tmp/joystick-03-petals.png' });
  console.log('  Screenshot: /tmp/joystick-03-petals.png');

  // ---- Test 6: Drag-release over the Quick Router petal commits ----
  console.log('\nTest 6: Drag-release over the Quick Router petal opens the panel...');
  const petalCenter = await page.evaluate(() => {
    const p = document.querySelector("[data-joystick-menu-target='petal'][data-petal-key='quick-router']");
    const b = p.getBoundingClientRect();
    return { cx: b.x + b.width / 2, cy: b.y + b.height / 2 };
  });
  await page.mouse.move(petalCenter.cx, petalCenter.cy, { steps: 6 });
  await page.waitForTimeout(150);
  const activeWhileOver = await page.evaluate(() =>
    document.querySelector("[data-joystick-menu-target='petal'][data-petal-key='quick-router']").getAttribute('data-active')
  );
  await page.mouse.up();
  await page.waitForTimeout(500);
  const committed = await page.evaluate(() => {
    const panel = document.querySelector('[data-chat-bubble-target="panel"]');
    const ps = Array.from(document.querySelectorAll("[data-joystick-menu-target='petal']"));
    return {
      panelOpen: panel.classList.contains('translate-x-0') && panel.classList.contains('opacity-100'),
      header: document.querySelector('#chat-bubble h3')?.textContent.trim(),
      petalsCollapsed: ps.every(p => getComputedStyle(p).opacity === '0' || p.style.transform === 'translate(0px, 0px)')
    };
  });
  assert(activeWhileOver === 'true', 'Petal highlights (data-active) while pointer is over it');
  assert(committed.panelOpen === true, 'Releasing over the Quick Router petal opens the panel');
  assert(committed.header === 'Quick Router', 'Committed action opened the Quick Router');
  assert(committed.petalsCollapsed === true, 'Petals collapse after drag-release');

  // ---- Summary ----
  console.log(`\n=== Results: ${passed} PASS, ${failed} FAIL ===`);
  console.log('=== Joystick Menu E2E Tests Complete ===');

  await page.close();
  await context.close();
  await browser.close();

  if (failed > 0) process.exit(1);
})();
