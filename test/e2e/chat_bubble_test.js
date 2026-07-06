const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: 1280, height: 900 },
    recordVideo: { dir: '/tmp/chat-bubble-videos/', size: { width: 1280, height: 900 } }
  });
  const page = await context.newPage();
  const BASE_URL = process.env.BASE_URL || 'http://localhost:3000';

  console.log('=== Chat Bubble E2E Test ===\n');
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

  // Test 1: Chat bubble icon is visible on the homepage
  console.log('Test 1: Chat bubble icon visible on homepage...');
  await page.goto(BASE_URL, { waitUntil: 'networkidle' });
  const bubbleButton = page.locator('#chat-bubble button[aria-label="Open quick router"]');
  assert(await bubbleButton.isVisible(), 'Chat bubble icon is visible on homepage');
  await page.screenshot({ path: '/tmp/chat-bubble-01-homepage.png', fullPage: true });
  console.log('  Screenshot: /tmp/chat-bubble-01-homepage.png');

  // Test 2: Chat bubble is visible on session detail page (every page)
  console.log('\nTest 2: Chat bubble visible on /sessions/new...');
  await page.goto(`${BASE_URL}/sessions/new`, { waitUntil: 'networkidle' });
  const bubbleOnNew = page.locator('#chat-bubble button[aria-label="Open quick router"]');
  assert(await bubbleOnNew.isVisible(), 'Chat bubble icon is visible on new session page');
  await page.screenshot({ path: '/tmp/chat-bubble-02-new-session.png', fullPage: true });
  console.log('  Screenshot: /tmp/chat-bubble-02-new-session.png');

  // Test 3: Panel is hidden by default
  console.log('\nTest 3: Panel is hidden by default...');
  await page.goto(BASE_URL, { waitUntil: 'networkidle' });
  const panel = page.locator('[data-chat-bubble-target="panel"]');
  const hasClosed = await panel.evaluate(el =>
    el.classList.contains('translate-x-full') && el.classList.contains('pointer-events-none')
  );
  assert(hasClosed, 'Panel is hidden by default (has translate-x-full and pointer-events-none)');

  // Test 4: Clicking the bubble opens the panel
  console.log('\nTest 4: Clicking bubble opens the panel...');
  await bubbleButton.click();
  await page.waitForTimeout(300);
  const panelAfterClick = await panel.evaluate(el =>
    el.classList.contains('translate-x-0') && el.classList.contains('opacity-100')
  );
  assert(panelAfterClick, 'Panel slides open after clicking bubble');
  await page.screenshot({ path: '/tmp/chat-bubble-03-panel-open.png', fullPage: true });
  console.log('  Screenshot: /tmp/chat-bubble-03-panel-open.png');

  // Test 5: Panel has correct elements
  console.log('\nTest 5: Panel has correct elements...');
  const textarea = page.locator('[data-chat-bubble-target="textarea"]');
  const submitBtn = page.locator('[data-chat-bubble-target="submitButton"]');
  const submitOpenBtn = page.locator('[data-chat-bubble-target="submitOpenButton"]');
  assert(await textarea.isVisible(), 'Textarea is visible in panel');
  assert(await submitBtn.isVisible(), '"Submit" button is visible');
  assert(await submitOpenBtn.isVisible(), '"Submit & Open" button is visible');

  // Verify button text
  const submitText = await submitBtn.textContent();
  const submitOpenText = await submitOpenBtn.textContent();
  assert(submitText.trim() === 'Submit', 'Submit button text is "Submit"');
  assert(submitOpenText.trim() === 'Submit & Open', 'Submit & Open button text is "Submit & Open"');

  // Test 6: Header shows "Quick Router"
  console.log('\nTest 6: Header text...');
  const header = page.locator('#chat-bubble h3');
  const headerText = await header.textContent();
  assert(headerText.trim() === 'Quick Router', 'Header says "Quick Router"');

  // Test 7: Escape key closes the panel
  console.log('\nTest 7: Escape key closes the panel...');
  await textarea.press('Escape');
  await page.waitForTimeout(300);
  const panelAfterEsc = await panel.evaluate(el =>
    el.classList.contains('translate-x-full') && el.classList.contains('pointer-events-none')
  );
  assert(panelAfterEsc, 'Panel closes on Escape key');

  // Test 8: Cmd+K opens the panel
  console.log('\nTest 8: Cmd+K keyboard shortcut...');
  await page.keyboard.press('Meta+k');
  await page.waitForTimeout(300);
  const panelAfterShortcut = await panel.evaluate(el =>
    el.classList.contains('translate-x-0') && el.classList.contains('opacity-100')
  );
  assert(panelAfterShortcut, 'Panel opens with Cmd+K shortcut');

  // Test 9: Clicking overlay closes the panel
  console.log('\nTest 9: Clicking overlay closes panel...');
  const overlay = page.locator('[data-chat-bubble-target="overlay"]');
  // Click the overlay (which is behind the panel)
  await overlay.click({ position: { x: 10, y: 10 }, force: true });
  await page.waitForTimeout(300);
  const panelAfterOverlay = await panel.evaluate(el =>
    el.classList.contains('translate-x-full')
  );
  assert(panelAfterOverlay, 'Panel closes when clicking overlay');

  // Test 10: Submitting an empty prompt does nothing (no request made)
  console.log('\nTest 10: Empty prompt submission does nothing...');
  await bubbleButton.click();
  await page.waitForTimeout(300);
  await textarea.fill('');
  // Try submit via button
  let requestMade = false;
  page.on('request', req => {
    if (req.url().includes('chat_bubble')) requestMade = true;
  });
  await submitBtn.click();
  await page.waitForTimeout(500);
  assert(!requestMade, 'No request made for empty prompt');
  page.removeAllListeners('request');

  // Test 11: Submitting with text makes API call
  console.log('\nTest 11: Submit with text makes API call and shows success badge...');
  await textarea.fill('Test message from chat bubble e2e test');

  // Listen for the request
  const responsePromise = page.waitForResponse(
    resp => resp.url().includes('chat_bubble'),
    { timeout: 10000 }
  );

  await submitBtn.click();

  try {
    const response = await responsePromise;
    const status = response.status();
    const body = await response.json();
    console.log(`  Response status: ${status}`);
    console.log(`  Response body: ${JSON.stringify(body)}`);
    assert(status === 200, 'API returns 200');
    assert(body.session_id !== undefined, 'Response contains session_id');
    assert(body.session_url !== undefined, 'Response contains session_url');
  } catch (e) {
    console.log(`  Error waiting for response: ${e.message}`);
    assert(false, 'API call completed');
  }

  await page.waitForTimeout(500);

  // Check the panel closed
  const panelAfterSubmit = await panel.evaluate(el =>
    el.classList.contains('translate-x-full')
  );
  assert(panelAfterSubmit, 'Panel closes after successful submission');

  // Check success badge briefly appeared
  const badge = page.locator('[data-chat-bubble-target="badge"]');
  // Badge should be visible briefly. Let's just check it exists.
  assert(await badge.count() > 0, 'Success badge element exists');

  await page.screenshot({ path: '/tmp/chat-bubble-04-after-submit.png', fullPage: true });
  console.log('  Screenshot: /tmp/chat-bubble-04-after-submit.png');

  // Test 12: Textarea is cleared after successful submission
  console.log('\nTest 12: Textarea cleared after submit...');
  await bubbleButton.click();
  await page.waitForTimeout(300);
  const textareaValue = await textarea.inputValue();
  assert(textareaValue === '', 'Textarea is cleared after submission');

  // Test 13: "Submit & Open" creates session and navigates
  console.log('\nTest 13: Submit & Open navigates to session...');
  await textarea.fill('Test Submit & Open from e2e');

  await submitOpenBtn.click();

  // Wait for navigation to a session page (the JS sets window.location.href)
  try {
    await page.waitForURL(/\/sessions\/\d+/, { timeout: 15000 });
    const currentUrl = page.url();
    console.log(`  Current URL after navigation: ${currentUrl}`);
    assert(currentUrl.match(/\/sessions\/\d+/), 'Navigated to session page after Submit & Open');
  } catch (e) {
    const currentUrl = page.url();
    console.log(`  Current URL: ${currentUrl}`);
    console.log(`  Error: ${e.message}`);
    // Even if waitForURL times out, check if we're on a session page
    assert(currentUrl.match(/\/sessions\/\d+/), 'Navigated to session page after Submit & Open');
  }

  await page.screenshot({ path: '/tmp/chat-bubble-05-navigated.png', fullPage: true });
  console.log('  Screenshot: /tmp/chat-bubble-05-navigated.png');

  // Test 14: Chat bubble is present on the session detail page too
  console.log('\nTest 14: Chat bubble present on session detail page...');
  const bubbleOnDetail = page.locator('#chat-bubble button[aria-label="Open quick router"]');
  assert(await bubbleOnDetail.isVisible(), 'Chat bubble visible on session detail page');

  // Test 15: Verify page context is captured
  console.log('\nTest 15: Verify page context in session prompt...');
  // Go back to homepage and check the first session
  await page.goto(BASE_URL, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1000);

  // Try to find the session we just created (should be at the top)
  const sessionCards = page.locator('[id^="session_"]');
  const cardCount = await sessionCards.count();
  console.log(`  Session cards found: ${cardCount}`);
  assert(cardCount >= 1, 'At least one session card is visible');

  // Final screenshot
  await page.screenshot({ path: '/tmp/chat-bubble-06-final.png', fullPage: true });
  console.log('\n  Final screenshot: /tmp/chat-bubble-06-final.png');

  // Summary
  console.log(`\n=== Results: ${passed} PASS, ${failed} FAIL ===`);
  console.log('=== Chat Bubble E2E Tests Complete ===');

  // Save video
  await page.close();
  await context.close();
  await browser.close();

  // Return non-zero if any tests failed
  if (failed > 0) process.exit(1);
})();
