/**
 * Mock Anthropic API server for e2e testing with the real Claude Code binary.
 *
 * Simulates the Anthropic Messages API and OAuth profile endpoint with
 * configurable per-account quota behavior. The real Claude Code binary
 * connects to this server via ANTHROPIC_BASE_URL environment variable.
 *
 * Usage:
 *   const { createMockAnthropicServer } = require('./mock_anthropic_server');
 *   const server = createMockAnthropicServer({
 *     accounts: {
 *       'token-account-1': { email: 'a@test.com', utilization5h: 0.45, utilization7d: 0.30 },
 *       'token-account-2': { email: 'b@test.com', quotaLimitAfterCalls: 2 },
 *     }
 *   });
 *   const { port } = await server.start();
 *   // Claude Code binary uses: ANTHROPIC_BASE_URL=http://127.0.0.1:<port>
 *   await server.stop();
 */

const http = require('http');

/**
 * Create a mock Anthropic API server.
 *
 * @param {Object} options
 * @param {Object} options.accounts - Map of access_token -> account config
 *   Each account config: {
 *     email: string,
 *     subscriptionType: string (default 'pro'),
 *     rateLimitTier: string (default 'tier_4'),
 *     utilization5h: number (0-1),
 *     utilization7d: number (0-1),
 *     status5h: string (default 'allowed'),
 *     status7d: string (default 'allowed'),
 *     quotaLimitAfterCalls: number|null - return quota limit error after N successful calls
 *   }
 * @param {boolean} options.verbose - Log requests to console (default false)
 * @returns {Object} Server with start(), stop(), getCallLog(), updateAccount() methods
 */
function createMockAnthropicServer(options = {}) {
  const accounts = new Map();
  const callLog = [];
  let server = null;
  let port = null;
  const verbose = options.verbose || false;

  // Initialize accounts
  for (const [token, config] of Object.entries(options.accounts || {})) {
    accounts.set(token, {
      email: config.email || 'test@example.com',
      subscriptionType: config.subscriptionType || 'pro',
      rateLimitTier: config.rateLimitTier || 'tier_4',
      utilization5h: config.utilization5h ?? 0.0,
      utilization7d: config.utilization7d ?? 0.0,
      status5h: config.status5h || 'allowed',
      status7d: config.status7d || 'allowed',
      quotaLimitAfterCalls: config.quotaLimitAfterCalls ?? null,
      callCount: 0,
    });
  }

  function log(...args) {
    if (verbose) console.log('[MockAnthropicServer]', ...args);
  }

  function handleRequest(req, res) {
    const url = new URL(req.url, `http://localhost:${port}`);
    let body = '';

    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      // Extract token from headers (API key or Bearer token)
      const apiKey = req.headers['x-api-key'];
      const bearer = (req.headers['authorization'] || '').replace('Bearer ', '');
      const token = apiKey || bearer;

      const entry = {
        method: req.method,
        path: url.pathname,
        token: token || '(none)',
        timestamp: new Date().toISOString(),
      };
      callLog.push(entry);
      log(`${req.method} ${url.pathname} token=${token ? token.substring(0, 20) + '...' : '(none)'}`);

      // Health check / HEAD request
      if (req.method === 'HEAD') {
        res.writeHead(200);
        res.end();
        return;
      }

      if (url.pathname === '/api/oauth/profile') {
        handleProfile(token, res);
      } else if (url.pathname === '/v1/messages') {
        handleMessages(token, body, res);
      } else {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'not_found' }));
      }
    });
  }

  function handleProfile(token, res) {
    const account = accounts.get(token);
    if (!account) {
      // Return generic profile for unknown tokens (QuotaCheckService still works)
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        account: { email: 'unknown@example.com' },
        organization: { organization_type: 'pro', rate_limit_tier: 'tier_4' },
      }));
      return;
    }

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      account: { email: account.email },
      organization: {
        organization_type: account.subscriptionType,
        rate_limit_tier: account.rateLimitTier,
      },
    }));
  }

  function handleMessages(token, body, res) {
    // For API key auth, find account by token
    // For unknown tokens, return a generic success (allows any claude binary to work)
    let account = accounts.get(token);
    if (!account) {
      // Check if the token matches any account (API key could differ from OAuth token)
      // Fall back to a default successful response
      log(`Unknown token, returning generic success`);
      return sendSuccessResponse(res, body, {
        utilization5h: 0.1,
        utilization7d: 0.05,
        status5h: 'allowed',
        status7d: 'allowed',
      });
    }

    account.callCount++;
    log(`Account ${account.email} call #${account.callCount} (limit after: ${account.quotaLimitAfterCalls})`);

    // Check if this account should return a quota limit error
    if (account.quotaLimitAfterCalls !== null && account.callCount > account.quotaLimitAfterCalls) {
      account.utilization5h = 1.0;
      account.status5h = 'exceeded';

      const resetTime = getResetTimeString();
      log(`Returning quota limit for ${account.email}`);

      const reset5h = Math.floor(Date.now() / 1000) + 18000;
      const reset7d = Math.floor(Date.now() / 1000) + 604800;

      res.writeHead(429, {
        'Content-Type': 'application/json',
        'anthropic-ratelimit-unified-5h-utilization': '1.0',
        'anthropic-ratelimit-unified-7d-utilization': String(Math.min(1.0, account.utilization7d + 0.3)),
        'anthropic-ratelimit-unified-5h-status': 'exceeded',
        'anthropic-ratelimit-unified-7d-status': account.status7d,
        'anthropic-ratelimit-unified-5h-reset': String(reset5h),
        'anthropic-ratelimit-unified-7d-reset': String(reset7d),
        'retry-after': '18000',
      });
      res.end(JSON.stringify({
        type: 'error',
        error: {
          type: 'rate_limit_error',
          message: `You've hit your limit \u00b7 resets ${resetTime} (UTC)`,
        },
      }));
      return;
    }

    // Normal successful response
    sendSuccessResponse(res, body, {
      utilization5h: account.utilization5h,
      utilization7d: account.utilization7d,
      status5h: account.status5h,
      status7d: account.status7d,
    });
  }

  function sendSuccessResponse(res, body, quotaInfo) {
    let parsed = {};
    try { parsed = JSON.parse(body); } catch (e) { /* ignore */ }
    const model = parsed.model || 'claude-sonnet-4-6';

    const reset5h = Math.floor(Date.now() / 1000) + 18000;
    const reset7d = Math.floor(Date.now() / 1000) + 604800;

    res.writeHead(200, {
      'Content-Type': 'application/json',
      'anthropic-ratelimit-unified-5h-utilization': String(quotaInfo.utilization5h),
      'anthropic-ratelimit-unified-7d-utilization': String(quotaInfo.utilization7d),
      'anthropic-ratelimit-unified-5h-status': quotaInfo.status5h,
      'anthropic-ratelimit-unified-7d-status': quotaInfo.status7d,
      'anthropic-ratelimit-unified-5h-reset': String(reset5h),
      'anthropic-ratelimit-unified-7d-reset': String(reset7d),
    });
    res.end(JSON.stringify({
      id: `msg_mock_${Date.now()}`,
      type: 'message',
      role: 'assistant',
      model: model,
      content: [{ type: 'text', text: 'I have completed the requested task.' }],
      stop_reason: 'end_turn',
      usage: { input_tokens: 100, output_tokens: 20 },
    }));
  }

  function getResetTimeString() {
    const now = new Date();
    const reset = new Date(now.getTime() + 5 * 60 * 60 * 1000);
    const hours = reset.getUTCHours();
    const ampm = hours >= 12 ? 'pm' : 'am';
    const hour12 = hours % 12 || 12;
    return `${hour12}${ampm}`;
  }

  return {
    /** Start the mock server on a random port. */
    start() {
      return new Promise((resolve, reject) => {
        server = http.createServer(handleRequest);
        server.listen(0, '127.0.0.1', () => {
          port = server.address().port;
          log(`Started on port ${port}`);
          resolve({ port });
        });
        server.on('error', reject);
      });
    },

    /** Stop the mock server. */
    stop() {
      return new Promise((resolve) => {
        if (server) {
          server.close(() => resolve());
        } else {
          resolve();
        }
      });
    },

    /** Get the log of all API calls. */
    getCallLog() {
      return [...callLog];
    },

    /** Update an account's configuration at runtime. */
    updateAccount(token, updates) {
      const account = accounts.get(token);
      if (account) {
        Object.assign(account, updates);
      }
    },

    /** Get current account state. */
    getAccount(token) {
      return accounts.get(token);
    },

    /** Get the port the server is listening on. */
    getPort() {
      return port;
    },

    /** Reset call counts for all accounts. */
    resetCallCounts() {
      for (const account of accounts.values()) {
        account.callCount = 0;
      }
    },

    /** Get all configured account tokens. */
    getAccountTokens() {
      return [...accounts.keys()];
    },
  };
}

module.exports = { createMockAnthropicServer };
