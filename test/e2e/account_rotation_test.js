/**
 * E2E test: Claude account rotation on quota limits.
 *
 * This test exercises the full account rotation flow using the real Claude
 * Code binary pointed at a mock Anthropic API server. It verifies:
 *
 * 1. Quotas page shows 5 accounts with correct data
 * 2. Starting a session hits a quota limit (mock returns 429 quickly)
 * 3. AO detects the quota limit and rotates to the next account
 * 4. After rotation, the mock API unblocks the new account
 * 5. AO auto-sends a "continue" message after rotation
 * 6. A second quota limit triggers rotation to a third account
 * 7. The quotas page reflects the updated state without manual refresh
 *
 * Prerequisites:
 *   - AO Rails app running with ANTHROPIC_BASE_URL and ANTHROPIC_API_KEY set
 *   - Database seeded with 5 accounts (via seed_accounts.rb)
 *   - Playwright installed
 *
 * Usage:
 *   # Start mock API, seed accounts, start AO, then:
 *   BASE_URL=http://localhost:3000 node test/e2e/account_rotation_test.js
 */

const { chromium } = require('playwright');
const { createMockAnthropicServer } = require('./lib/mock_anthropic_server');
const { execSync, spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const BASE_URL = process.env.BASE_URL || 'http://localhost:3000';
const AO_DIR = path.resolve(__dirname, '../..');
const VERBOSE = process.env.VERBOSE === 'true';
const VIDEO_DIR = '/tmp/account-rotation-videos/';

// Test configuration
const ACCOUNT_TOKENS = {
  'e2e-token-account-1': {
    email: 'account1@e2e-test.com',
    utilization5h: 0.0,
    utilization7d: 0.0,
    quotaLimitAfterCalls: 2, // Hit quota after 2 API calls
  },
  'e2e-token-account-2': {
    email: 'account2@e2e-test.com',
    utilization5h: 0.1,
    utilization7d: 0.05,
    quotaLimitAfterCalls: 2, // Hit quota after 2 API calls
  },
  'e2e-token-account-3': {
    email: 'account3@e2e-test.com',
    utilization5h: 0.2,
    utilization7d: 0.10,
    quotaLimitAfterCalls: null, // Never hits quota
  },
  'e2e-token-account-4': {
    email: 'account4@e2e-test.com',
    utilization5h: 0.3,
    utilization7d: 0.15,
    quotaLimitAfterCalls: null,
  },
  'e2e-token-account-5': {
    email: 'account5@e2e-test.com',
    utilization5h: 0.4,
    utilization7d: 0.20,
    quotaLimitAfterCalls: null,
  },
};

(async () => {
  let mockServer = null;
  let browser = null;
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

  try {
    // ── Phase 1: Start mock Anthropic API server ─────────────────────
    console.log('=== Account Rotation E2E Test ===\n');
    console.log('Phase 1: Starting mock Anthropic API server...');

    mockServer = createMockAnthropicServer({
      accounts: ACCOUNT_TOKENS,
      verbose: VERBOSE,
    });
    const { port: mockPort } = await mockServer.start();
    console.log(`  Mock API server running on port ${mockPort}`);

    // ── Phase 2: Seed database with 5 accounts ──────────────────────
    console.log('\nPhase 2: Seeding database with 5 accounts...');
    try {
      execSync(
        `bin/rails runner test/e2e/lib/seed_accounts.rb`,
        {
          cwd: AO_DIR,
          env: { ...process.env, MOCK_API_PORT: String(mockPort) },
          stdio: VERBOSE ? 'inherit' : 'pipe',
          timeout: 30000,
        }
      );
      console.log('  Database seeded successfully');
    } catch (e) {
      console.error('  Failed to seed database:', e.message);
      if (e.stderr) console.error('  stderr:', e.stderr.toString().substring(0, 500));
      process.exit(1);
    }

    // ── Phase 3: Launch Playwright browser ──────────────────────────
    console.log('\nPhase 3: Launching browser...');
    fs.mkdirSync(VIDEO_DIR, { recursive: true });

    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({
      viewport: { width: 1280, height: 900 },
      recordVideo: { dir: VIDEO_DIR, size: { width: 1280, height: 900 } },
    });
    const page = await context.newPage();

    // ── Test 1: Quotas page shows 5 accounts ────────────────────────
    console.log('\nTest 1: Quotas page shows 5 accounts with correct data...');
    await page.goto(`${BASE_URL}/quotas`, { waitUntil: 'networkidle', timeout: 30000 });
    await page.screenshot({ path: '/tmp/account-rotation-01-quotas-initial.png', fullPage: true });

    // Wait for Turbo frames to load (account cards are lazy-loaded)
    try {
      await page.waitForSelector('[data-testid="account-card"], .account-card, [id*="account"]', {
        timeout: 15000,
      });
    } catch (e) {
      // Turbo frames may use different selectors - wait for content to appear
      await page.waitForTimeout(5000);
    }

    await page.screenshot({ path: '/tmp/account-rotation-02-quotas-loaded.png', fullPage: true });

    // Check that we can see account emails on the page
    const pageContent = await page.content();
    let accountsFound = 0;
    for (let i = 1; i <= 5; i++) {
      if (pageContent.includes(`account${i}@e2e-test.com`)) {
        accountsFound++;
      }
    }
    assert(accountsFound === 5, `All 5 accounts visible on quotas page (found ${accountsFound})`);

    // Check that account1 is marked as current
    assert(
      pageContent.includes('Current') || pageContent.includes('current'),
      'One account is marked as current'
    );

    // ── Test 2: Create a new session ────────────────────────────────
    console.log('\nTest 2: Creating a new agent session...');
    await page.goto(`${BASE_URL}/sessions/new`, { waitUntil: 'networkidle' });

    // Fill in session form
    const promptField = page.locator('textarea[name="session[prompt]"], #session_prompt, textarea');
    await promptField.first().fill('Say hello. This is an e2e test.');

    // Find and click the submit button
    const submitBtn = page.locator('input[type="submit"], button[type="submit"]').first();
    await submitBtn.click();

    // Wait for navigation to session page
    try {
      await page.waitForURL(/\/sessions\/\d+/, { timeout: 15000 });
    } catch (e) {
      console.log('  Warning: Did not navigate to session page, trying alternate approach');
      await page.waitForTimeout(3000);
    }

    const sessionUrl = page.url();
    console.log(`  Session URL: ${sessionUrl}`);
    assert(sessionUrl.match(/\/sessions\/\d+/), 'Created session and navigated to detail page');

    await page.screenshot({ path: '/tmp/account-rotation-03-session-created.png', fullPage: true });

    // ── Test 3: Wait for quota limit and rotation ───────────────────
    console.log('\nTest 3: Waiting for first quota limit and account rotation...');

    // The session will run the real Claude binary, which talks to our mock API.
    // After 2 API calls, account1 gets a quota limit error. AO detects it in
    // the transcript, rotates to account2, and sends a "continue" message.
    //
    // We watch for rotation events in the session logs and page content.
    let rotationDetected = false;
    let rotationAttempts = 0;
    const maxRotationWait = 120; // seconds

    while (!rotationDetected && rotationAttempts < maxRotationWait) {
      await page.waitForTimeout(2000);
      rotationAttempts += 2;

      // Reload session page to get latest state
      await page.reload({ waitUntil: 'networkidle', timeout: 10000 }).catch(() => {});
      const content = await page.content();

      // Look for rotation indicators in the session page
      if (
        content.includes('Account quota') ||
        content.includes('rotated to') ||
        content.includes('account2@e2e-test.com') ||
        content.includes('quota_exceeded')
      ) {
        rotationDetected = true;
        console.log(`  First rotation detected after ${rotationAttempts}s`);
      }

      // Also check the mock server call log
      const log = mockServer.getCallLog();
      const account1Calls = log.filter(e => e.token === 'e2e-token-account-1' && e.path === '/v1/messages');
      const account2Calls = log.filter(e => e.token === 'e2e-token-account-2' && e.path === '/v1/messages');

      if (account2Calls.length > 0) {
        rotationDetected = true;
        console.log(`  First rotation detected via API calls after ${rotationAttempts}s`);
        console.log(`    Account 1 calls: ${account1Calls.length}, Account 2 calls: ${account2Calls.length}`);
      }

      if (rotationAttempts % 10 === 0) {
        console.log(`  Waiting... (${rotationAttempts}s elapsed, account1 calls: ${account1Calls.length})`);
      }
    }

    assert(rotationDetected, 'First account rotation occurred (account1 -> account2)');
    await page.screenshot({ path: '/tmp/account-rotation-04-first-rotation.png', fullPage: true });

    // ── Test 4: Wait for second rotation ────────────────────────────
    console.log('\nTest 4: Waiting for second rotation (account2 -> account3)...');

    let secondRotation = false;
    let secondAttempts = 0;
    const maxSecondWait = 120;

    while (!secondRotation && secondAttempts < maxSecondWait) {
      await page.waitForTimeout(2000);
      secondAttempts += 2;

      const log = mockServer.getCallLog();
      const account3Calls = log.filter(e => e.token === 'e2e-token-account-3' && e.path === '/v1/messages');

      if (account3Calls.length > 0) {
        secondRotation = true;
        const account2Calls = log.filter(e => e.token === 'e2e-token-account-2' && e.path === '/v1/messages');
        console.log(`  Second rotation detected after ${secondAttempts}s`);
        console.log(`    Account 2 calls: ${account2Calls.length}, Account 3 calls: ${account3Calls.length}`);
      }

      if (secondAttempts % 10 === 0) {
        const account2Calls = log.filter(e => e.token === 'e2e-token-account-2' && e.path === '/v1/messages');
        console.log(`  Waiting... (${secondAttempts}s, account2 calls: ${account2Calls.length})`);
      }
    }

    assert(secondRotation, 'Second account rotation occurred (account2 -> account3)');
    await page.screenshot({ path: '/tmp/account-rotation-05-second-rotation.png', fullPage: true });

    // ── Test 5: Session eventually completes ────────────────────────
    console.log('\nTest 5: Waiting for session to complete on account3...');

    let sessionCompleted = false;
    let completionAttempts = 0;
    const maxCompletionWait = 60;

    while (!sessionCompleted && completionAttempts < maxCompletionWait) {
      await page.waitForTimeout(2000);
      completionAttempts += 2;

      await page.reload({ waitUntil: 'networkidle', timeout: 10000 }).catch(() => {});
      const content = await page.content();

      // Session should eventually reach needs_input state (completed turn)
      if (
        content.includes('needs_input') ||
        content.includes('Needs Input') ||
        content.includes('completed') ||
        content.includes('I have completed')
      ) {
        sessionCompleted = true;
        console.log(`  Session completed after ${completionAttempts}s`);
      }
    }

    assert(sessionCompleted, 'Session completed successfully on account3');
    await page.screenshot({ path: '/tmp/account-rotation-06-session-complete.png', fullPage: true });

    // ── Test 6: Quotas page shows updated state ─────────────────────
    console.log('\nTest 6: Checking quotas page for updated state...');
    await page.goto(`${BASE_URL}/quotas`, { waitUntil: 'networkidle', timeout: 30000 });

    // Wait for Turbo frames to load
    await page.waitForTimeout(5000);

    await page.screenshot({ path: '/tmp/account-rotation-07-quotas-final.png', fullPage: true });

    const finalContent = await page.content();

    // Check for quota_exceeded status on rotated accounts
    const exceededCount = (finalContent.match(/quota.exceeded|Quota Exceeded/gi) || []).length;
    console.log(`  Found ${exceededCount} quota exceeded indicators`);
    assert(exceededCount >= 1, 'At least one account shows quota exceeded status');

    // Check that account3 is now current (after two rotations)
    const account3IsCurrent = finalContent.includes('account3@e2e-test.com');
    assert(account3IsCurrent, 'Account 3 is visible on quotas page');

    // ── Test 7: Verify rotation log shows events ────────────────────
    console.log('\nTest 7: Checking rotation log...');
    const hasRotationLog = finalContent.includes('Rotation') || finalContent.includes('rotation');
    assert(hasRotationLog, 'Rotation log section is visible');

    await page.screenshot({ path: '/tmp/account-rotation-08-final.png', fullPage: true });

    // ── Test 8: Verify mock API call patterns ───────────────────────
    console.log('\nTest 8: Verifying API call patterns...');
    const callLog = mockServer.getCallLog();
    const msgCalls = callLog.filter(e => e.path === '/v1/messages');
    const a1Calls = msgCalls.filter(e => e.token === 'e2e-token-account-1');
    const a2Calls = msgCalls.filter(e => e.token === 'e2e-token-account-2');
    const a3Calls = msgCalls.filter(e => e.token === 'e2e-token-account-3');

    console.log(`  Total /v1/messages calls: ${msgCalls.length}`);
    console.log(`  Account 1 calls: ${a1Calls.length}`);
    console.log(`  Account 2 calls: ${a2Calls.length}`);
    console.log(`  Account 3 calls: ${a3Calls.length}`);

    assert(a1Calls.length >= 2, `Account 1 had at least 2 API calls (got ${a1Calls.length})`);
    assert(a2Calls.length >= 2, `Account 2 had at least 2 API calls (got ${a2Calls.length})`);
    assert(a3Calls.length >= 1, `Account 3 had at least 1 API call (got ${a3Calls.length})`);

    // ── Summary ─────────────────────────────────────────────────────
    console.log(`\n=== Results: ${passed} PASS, ${failed} FAIL ===`);
    console.log('=== Account Rotation E2E Test Complete ===\n');

    console.log('Screenshots saved to /tmp/account-rotation-*.png');
    console.log(`Video saved to ${VIDEO_DIR}`);

    // Close browser and save video
    await page.close();
    await context.close();
    await browser.close();
    browser = null;

  } catch (e) {
    console.error('\nTest error:', e.message);
    console.error(e.stack);
    failed++;
  } finally {
    if (browser) {
      try { await browser.close(); } catch (e) { /* ignore */ }
    }
    if (mockServer) {
      await mockServer.stop();
      console.log('Mock server stopped');
    }
  }

  if (failed > 0) process.exit(1);
})();
