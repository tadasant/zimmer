---
name: zimmer-run-tests
title: Run Zimmer's Tests
description: >
  Run the right slice of Zimmer's test suite for a change and reproduce CI
  locally. Covers the four tiers (Minitest unit/integration, Capybara system
  tests, Playwright e2e scripts, the standalone GHCR retention test), which of
  them CI actually gates on, the Postgres + Redis prerequisites, and the lint /
  Brakeman / Gemfile.lock jobs that fail PRs as often as the tests do. Use before
  pushing any change to this repo.
user-invocable: true
---

# Run Zimmer's Tests

Zimmer's house rule (`AGENTS.md`): run **targeted** tests locally, let CI run the
full suite. Always run Rails/bundler commands from the repo root.

## What CI gates on

`.github/workflows/ci.yml` runs on every PR to `main` and every push to `main`.
A PR is red if **any** job fails:

| Job | Command | Notes |
| --- | --- | --- |
| `lint` | `bin/rubocop -f github --parallel` | `rubocop-rails-omakase` |
| `security` | `bin/brakeman --no-pager -q` | |
| `verify_lockfile` | `bundle lock && git diff --exit-code Gemfile.lock` | Fails if `Gemfile.lock` is stale |
| `test-unit` | `bin/rails db:test:prepare && bin/rails test` | Unit + integration. Postgres 16 + Redis 7 services |
| `test-system` | `bin/rails test:system` | Capybara + headless Chrome. `PARALLEL_WORKERS=1` |
| `retention_logic` | `ruby scripts/ghcr_retention_test.rb` | Pure Ruby, no Rails boot |
| `docs_site` | `npm run build` in `docs/` | Astro Starlight build |
| `all-checks-pass` | Aggregate gate | `needs:` every job above; the single required check for branch protection |

Two things fall out of that table:

- **System tests ARE run by CI**, in the `test-system` job — `bin/rails test`
  does not descend into `test/system/`, so it gets its own job. If your change
  touches views, Stimulus controllers, or Turbo streams, run them yourself
  before pushing: a regression there *will* turn the PR red.
- **The Playwright e2e scripts in `test/e2e/` are NOT run by CI**, and no
  workflow invokes them (the runner has no Playwright browser). Tracked in
  [#162](https://github.com/tadasant/zimmer/issues/162).

So "CI is green" means: Rubocop, Brakeman, the lockfile, the Minitest suite
(unit + integration), the system suite, the retention selector, and the docs
build. Everything except `test/e2e/`.

## Prerequisites

The test suite needs **Postgres and Redis running** — the same services CI spins
up. `test/test_helper.rb` hard-aborts unless `Rails.env == test` and the database
name ends in `_test`, so it will not touch your dev DB.

```bash
bin/rails db:test:prepare
```

The suite also pre-installs the AIR CLI and pre-warms the artifact catalog at
boot (before `parallelize` forks its workers). A catalog that does not resolve
therefore breaks the suite *globally*, not in one test — see
`skills/zimmer-change-ai-artifact` if you touched `air.json` or the artifact
indexes.

## Tier 1 — Minitest (unit + integration; the `test-unit` job)

```bash
bin/rails test                                     # everything except system tests
bin/rails test test/models/session_test.rb         # one file
bin/rails test test/services/                      # one directory
bin/rails test test/models/session_test.rb:42      # one test, by line
```

`https://docs.zimmer.tadasant.com/operate/testing/` recommends bounding local runs so a hang doesn't eat
your session:

```bash
timeout 60 bin/rails test test/services/my_service_test.rb
```

Suites live under `test/`: `models`, `services`, `controllers` (incl. `api/v1`,
`supervisor`), `integration`, `jobs`, `lib`, `contracts`, `extensions`, `helpers`,
`mailers`, `initializers`, `config`.

## Tier 2 — System tests (Capybara + headless Chrome; the `test-system` job)

Gated by CI. Run them yourself when you touch views, Stimulus controllers, or
Turbo streams — CI runs them serially (`PARALLEL_WORKERS=1`), so it is cheaper
to catch a break locally than to wait for the job.

```bash
bin/rails test:system                              # all of test/system/
bin/rails test test/system/sessions_test.rb        # one file
HEADLESS=false bin/rails test test/system/smoke_test.rb   # watch it in a real browser
```

`test/application_system_test_case.rb` drives `:selenium_chrome_headless`, with
per-worker Chrome user-data dirs under `tmp/chrome_user_data` and per-worker
Capybara ports from 9800. Helpers worth knowing:
`wait_for_turbo_streams_connected`, `select_agent_root`, `js_click`,
`scroll_into_center`.

## Tier 3 — Playwright e2e scripts

Plain Node scripts against a **running dev server** — no runner, no npm script,
not in CI. Start the server first (`skills/zimmer-start-dev-server`), then:

```bash
BASE_URL=http://localhost:3000 node test/e2e/skills_catalog_test.js
```

Available: `account_rotation_test.js`, `chat_bubble_test.js`,
`joystick_menu_test.js`, `skills_catalog_test.js`. Support code lives in
`test/e2e/lib/` (`mock_anthropic_server.js`, `seed_accounts.rb`).

## Tier 4 — Standalone

```bash
ruby scripts/ghcr_retention_test.rb    # no Rails boot
```

## Before you push

Reproduce the three cheap CI jobs locally — they fail PRs as often as the tests:

```bash
bin/rubocop            # add -a to autocorrect
bin/brakeman --no-pager -q
bundle lock && git diff --exit-code Gemfile.lock   # must be clean
```

Then push and **block on CI** with the `wait-for-ci` skill rather than assuming
green. Never present a pushed commit as done without confirming CI passed.

## A known-failing baseline

`CONTRIBUTING.md` documents a coupling to the agent-artifact catalog: session-
creating tests (anything through `Session.create_from_agent_root!`) depend on the
catalog resolving to non-empty data. If you see a wave of
`ActiveRecord::RecordInvalid` failures across unrelated session tests, suspect
catalog resolution — not your change. Verify with:

```bash
AIR_CONFIG=$PWD/air.json ~/.cache/air-cli/node_modules/.bin/air \
  resolve --json --no-scope --git-protocol https | ruby -rjson -e \
  'j=JSON.parse($stdin.read); j.each { |k, v| puts "#{k}: #{v.size}" }'
```

Every artifact type should be non-empty.
